---
title: Graphics.DrawMeshInstanced 单批实例数量影响因素实验
date: 2026-02-13 14:10:00 +0800
categories: [Unity, Graphics]
tags: [gpu-instancing, drawmeshinstanced, srp-batcher]
description: 探究 Unity GPU Instancing 下单批最多能绘制多少个实例，以及常量缓冲区、矩阵与 Per-Instance 属性对批次上限的影响。
render_with_liquid: false
---

## 背景

全场景大部分用单位 Cube 绘制，同一 Shader、材质属性不同，希望从 SRP Batch 改为 GPU Instancing，理论上能提升绘制性能。本文记录一次围绕 `Graphics.DrawMeshInstanced` 单批可绘制实例数量的实验与优化过程。

## Shader 修改：支持 Instancing

在原有 Shader 上增加 Instancing 相关部分。

### 1. Pass 中声明关键字

```hlsl
#pragma multi_compile_instancing
```

### 2. 声明 Instancing 属性块

```hlsl
UNITY_INSTANCING_BUFFER_START(Props)
    UNITY_DEFINE_INSTANCED_PROP(float4, _Color)
    // ... 其他属性
UNITY_INSTANCING_BUFFER_END(Props)

#define _Color UNITY_ACCESS_INSTANCED_PROP(Props, _Color)
```

### 3. 顶点/片元与 InstanceID

在顶点着色器输入/输出结构体中加入 `UNITY_VERTEX_INPUT_INSTANCE_ID`，并在顶点、片元着色器中调用 `SetupInstanceID`：

```hlsl
struct appdata
{
    float4 vertex : POSITION;
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

struct v2f
{
    float4 vertex : SV_POSITION;
    UNITY_VERTEX_INPUT_INSTANCE_ID  // 用于在片元着色器中访问 per-instance 属性
};

v2f vert(appdata v)
{
    v2f o;
    UNITY_SETUP_INSTANCE_ID(v);
    UNITY_TRANSFER_INSTANCE_ID(v, o);
    o.vertex = UnityObjectToClipPos(v.vertex);
    return o;
}

fixed4 frag(v2f i) : SV_Target
{
    UNITY_SETUP_INSTANCE_ID(i);
    return _Color;
}
```

## API 与批次上限

该 API 的单批实例数存在上限。脚本中通过 MaterialPropertyBlock 的 `Set***Array` 设置 per-instance 属性，并调用 `Graphics.DrawMeshInstanced`，将单次绘制数量限制在 **1023** 以内。

> 单批最多 1023 个实例的限制来自常量缓冲区（Constant Buffer）大小：多数设备上限为 64KB（65536 字节）。Unity 的 `ObjectToWorld` 矩阵占 64B，因此理论最大数量为 65536 / 64 − 1 = **1023**。
{: .prompt-info }

默认情况下还会上传 `WorldToObject` 矩阵，per-instance 数据量翻倍，因此实际一批往往只能画到约 **511** 个。

## 初次实验结果

在本例中，`Props` 里声明了较多 per-instance 属性，总大小超过了 128B，因此单批实际只能绘制 **371** 个实例，低于 511。

## 优化：压缩 Per-Instance 属性

每个在 Instancing 块里声明的属性，不论是否四通道，都会占用一个 `float4`（16 字节）的寄存器空间。将多个 `float` 合并为一个 `float4` 可以明显减少占用。

> **Props 的本质**：Instancing 的 Props 展开后是「结构体数组」，而不是「每个属性一个数组」。可参考 `UnityInstancing.hlsl` 第 243–246 行：
{: .prompt-tip }

```hlsl
#define UNITY_INSTANCING_BUFFER_START(buf)      UNITY_INSTANCING_CBUFFER_SCOPE_BEGIN(UnityInstancing_##buf) struct {
#define UNITY_INSTANCING_BUFFER_END(arr)        } arr##Array[UNITY_INSTANCED_ARRAY_SIZE]; UNITY_INSTANCING_CBUFFER_SCOPE_END
#define UNITY_DEFINE_INSTANCED_PROP(type, var)  type var;
#define UNITY_ACCESS_INSTANCED_PROP(arr, var)   arr##Array[unity_InstanceID].var
```

即等价于：

```hlsl
cbuffer UnityInstancing_Props {
    struct {
        half4 _Color;
        // ...
    } PropsArray[N];
}
```

在结构体内，HLSL 会按 **std140** 规则打包：连续标量可打包到同一 16 字节对齐单元。因此将 `half4` 等四分量属性靠前放、零散 `half`/`float` 靠后放，有利于自动打包，减少浪费。

按上述方式调整属性顺序后，单批可绘制实例数提升到 **408** 个。

## 验证：仅矩阵时的上限

为验证「矩阵数量决定 511 vs 1023」的说法，将所有 Props 注释掉，只保留矩阵相关数据。

在 `Graphics.RenderMeshInstanced` 文档中提到，可通过 `#pragma instancing_options assumeuniformscaling` 从实例数据中**去掉 WorldToObject 矩阵**。

加上该 pragma 后，单批可绘制 **584** 个。仍未到 1023，说明顶点变换路径中仍在使用 `WorldToObject`。将 Shader 里对 `WorldToObject` 的引用注释掉后，单批终于达到 **1023** 个。

> 584 的成因尚未完全确定。粗略估算：65536 / 584 ≈ 112 字节/实例；112 = 64 + 48，可能与「少传了一部分矩阵行」或其它隐式 per-instance 数据有关，留作后续排查。
{: .prompt-warning }

## 小结

| 情况 | 单批实例数 |
|------|------------|
| 默认（ObjectToWorld + WorldToObject + 多属性 Props） | 371 |
| 优化 Props 布局后 | 408 |
| 仅矩阵 + `assumeuniformscaling`，仍用 WorldToObject | 584 |
| 仅矩阵 + 去掉 WorldToObject 使用 | 1023 |

单批实例数由 **64KB 常量缓冲区** 与 **每实例数据大小**（矩阵 + Props）共同决定；通过合并属性、调整顺序、减少冗余矩阵，可以显著提高单批可画实例数。

## 参考

- [GPU instancing - Unity Manual](https://docs.unity3d.com/cn/2021.3/Manual/gpu-instancing-shader.html)
- [Graphics.RenderMeshInstanced - ScriptReference](https://docs.unity3d.com/2021.3/Documentation/ScriptReference/Graphics.RenderMeshInstanced.html)
- [Understanding instancing and DrawMeshInstanced - Unity Forum](https://discussions.unity.com/t/understanding-instancing-and-drawmeshinstanced/648902/3)
