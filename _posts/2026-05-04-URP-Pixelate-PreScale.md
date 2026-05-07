---
title: URP 像素化渲染：从后处理 Blit 到预缩放相机的完整实战
date: 2026-05-04 12:00:00 +0800
categories: [Unity, Rendering]
tags: [urp, renderfeature, pixelate, blitter, framebuffer]
description: 记录将 URP 像素化效果从"全分辨率渲染→降采样→升采样"的后处理方案，改造为"相机绑定低分辨率 RT→升采样输出"的预缩放方案，涵盖 ScriptableRenderFeature、RenderPipelineManager、帧调试器排查与 Y 轴翻转等踩坑细节。
media_subpath: /assets/img/2026-05-04-URP-Pixelate-PreScale/
image: PreviewImg.png
render_with_liquid: false
---

## 背景

原本的像素化效果采用**后处理**方式：相机正常以全分辨率（1920×1080）渲染整个场景，然后在 `AfterRenderingTransparents` 阶段做两次 Blit——第一次降采样到小 RT，第二次点采样放大回相机目标。这种方法简单直观，但几何、阴影、光照全部在全分辨率下计算，像素化只发生在最后一刻，性能浪费明显。

我们想要的效果是：**相机直接渲染到低分辨率 RT**，所有 pass 天然以低分辨率运行，帧末一次性放大到屏幕。这样不仅省去了降采样开销，更重要的是所有渲染计算都在缩减后的分辨率下进行。

## 方案对比

| | 旧方案（后处理 Blit） | 新方案（预缩放） |
|---|---|---|
| 渲染分辨率 | 1920×1080 | 480×270 (pixelSize=4) |
| Pass 数量 | 2 次 Blit（降 + 升） | 1 次 Blit（仅升） |
| 光栅化开销 | 全分辨率 | **1/16** (以 pixelSize=4 计) |
| Blit 时机 | `AfterRenderingTransparents` | `AfterRendering` |
| Scene View 影响 | 是 | 可开关 |

## 实现思路

URP 中要重定向相机渲染目标，关键是在 URP 读取相机属性**之前**把 `Camera.targetTexture` 劫持为小 RT。查了 URP 源码中 `RenderSingleCamera` 的调用顺序：

```
RenderPipelineManager.beginCameraRendering  ← 最早钩子
  → 读取 camera.pixelWidth/Height 计算 cameraTargetDescriptor
  → renderer.Setup() 创建内部 RT
  → 各 Pass 的 OnCameraSetup / Execute
  → ...
RenderPipelineManager.endCameraRendering
```

`beginCameraRendering` 是最早可用的扩展点，此时 URP 尚未读取相机尺寸。在这里设置 `camera.targetTexture = smallRT`，URP 随后读到的 `pixelWidth/Height` 就是小 RT 的尺寸，内部 RT 也随之缩小，所有后续渲染自动在低分辨率下运行。

然后需要一个 `ScriptableRenderPass` 在 `AfterRendering` 将小 RT 放大回屏幕。整体架构：

```
┌─ Create() ───────────────────────────────────┐
│  注册 beginCameraRendering 回调                │
│  创建 UpscalePass (AfterRendering)            │
└──────────────────────────────────────────────┘
                    │
    ┌───────────────▼──────────────────────────┐
    │ beginCameraRendering:                     │
    │   1. Screen.width / pixelSize → 小 RT     │
    │   2. camera.targetTexture = smallRT       │
    │   → URP 读到小尺寸，全链路低分辨率渲染      │
    └───────────────┬──────────────────────────┘
                    │
    ┌───────────────▼──────────────────────────┐
    │ UpscalePass.OnCameraSetup:                │
    │   camera.targetTexture = null (恢复屏幕)   │
    │                                           │
    │ UpscalePass.Execute:                      │
    │   Blitter.BlitCameraTexture(              │
    │     smallRT → CameraTarget,               │
    │     Point filter)                         │
    └──────────────────────────────────────────┘
```

## 完整代码

```csharp
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class PixelateRenderFeature : ScriptableRendererFeature
{
    [SerializeField] private int pixelSize = 4;
    [SerializeField] private bool applyToSceneView;

    private RTHandle _smallRT;
    private RTHandle _screenTarget;
    private UpscalePass _upscalePass;
    private Camera _lastCamera;
    private int _lastFrame;

    public override void Create()
    {
        _screenTarget = RTHandles.Alloc(BuiltinRenderTextureType.CameraTarget);
        _upscalePass = new UpscalePass(this);
        RenderPipelineManager.beginCameraRendering += OnBeginCameraRendering;
    }

    public override void AddRenderPasses(ScriptableRenderer renderer,
        ref RenderingData renderingData)
    {
        if (!ShouldApply(renderingData.cameraData.cameraType))
            return;
        renderer.EnqueuePass(_upscalePass);
    }

    private void OnBeginCameraRendering(ScriptableRenderContext context,
        Camera camera)
    {
        if (!ShouldApply(camera.cameraType))
            return;
        // 跳过预览缩略图、反射探针等已绑定 RT 的渲染
        if (camera.targetTexture != null)
            return;
        // 同帧同相机防重入（深度预通道/阴影贴图多轮触发）
        if (_lastCamera == camera && _lastFrame == Time.frameCount)
            return;
        _lastCamera = camera;
        _lastFrame = Time.frameCount;

        int w = Mathf.Max(1, Screen.width / pixelSize);
        int h = Mathf.Max(1, Screen.height / pixelSize);

        var desc = new RenderTextureDescriptor(w, h,
            RenderTextureFormat.Default, 0)
        { msaaSamples = 1, depthBufferBits = 0 };

        RenderingUtils.ReAllocateIfNeeded(ref _smallRT, desc,
            FilterMode.Point, TextureWrapMode.Clamp, name: "PixelRT");

        camera.targetTexture = _smallRT;
    }

    private bool ShouldApply(CameraType cameraType)
    {
        return cameraType is CameraType.Game or CameraType.VR
            || (applyToSceneView && cameraType == CameraType.SceneView);
    }

    protected override void Dispose(bool disposing)
    {
        RenderPipelineManager.beginCameraRendering -= OnBeginCameraRendering;
        _upscalePass = null;
        _smallRT?.Release();
        _smallRT = null;
        _screenTarget?.Release();
        _screenTarget = null;
    }

    private class UpscalePass : ScriptableRenderPass
    {
        private PixelateRenderFeature _feature;

        public UpscalePass(PixelateRenderFeature feature)
        {
            _feature = feature;
            renderPassEvent = RenderPassEvent.AfterRendering;
        }

        public override void OnCameraSetup(CommandBuffer cmd,
            ref RenderingData renderingData)
        {
            if (_feature._smallRT == null) return;
            var cam = renderingData.cameraData.camera;
            if ((bool)cam) cam.targetTexture = null;
        }

        public override void Execute(ScriptableRenderContext context,
            ref RenderingData renderingData)
        {
            if (_feature._smallRT == null) return;

            var cmd = CommandBufferPool.Get("PixelateUpscale");
            Blitter.BlitCameraTexture(cmd, _feature._smallRT,
                _feature._screenTarget,
                new Vector4(1, -1, 0, 1), 0, false);
            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }
    }
}
```

## OnBeginCameraRendering 三层过滤详解

`OnBeginCameraRendering` 回调中有三个 `if` 提前 `return`，构成三层安全过滤，确保像素化效果只精准作用于主相机的颜色渲染。

### 第一层：相机类型过滤 `ShouldApply(camera.cameraType)`

URP 中相机类型不止 Game 一种：

- **CameraType.Game / VR** — 主游戏画面和 VR 渲染，是像素化的目标，必须处理
- **CameraType.SceneView** — Editor 场景视图，由 `applyToSceneView` 开关控制，方便调试时预览像素化效果
- **CameraType.Preview** — 材质/模型缩略图预览的小相机，拦截会导致 Inspector 缩略图变成马赛克
- **CameraType.Reflection** — 反射探针相机，拦截会导致实时反射贴图出现像素块

如果不过滤，反射探针的 Cubemap、材质预览缩略图都会被降分辨率渲染，视觉效果全面崩坏。

### 第二层：独立渲染目标屏蔽 `camera.targetTexture != null`

有些相机渲染结果不走屏幕，而是输出到 RenderTexture 供其他地方使用：

- **反射探针** — 渲染到 Cubemap，用于实时反射
- **材质缩略图预览** — 渲染到 Inspector 底部的小预览窗
- **战斗头像 / 小地图** — 渲染到独立 RT 然后贴到 UI 上

这些相机的 `targetTexture` 已被上层逻辑设定为特定 RT。如果劫持它替换为 `_smallRT`，原来的渲染目标被篡改，反射探针贴图异常、头像预览花掉。此处直接放过，让它们走原路。

### 第三层：同帧同相机防重入

这是最隐蔽的坑。URP 的 `beginCameraRendering` 事件**不保证一帧对同一个相机只回调一次**，同帧内可能反复触发：

- **深度预通道（Depth Prepass）** — URP 先跑一次 Depth Pass 生成深度贴图，再跑颜色渲染，两次都触发事件
- **阴影贴图渲染** — 每个投射阴影的光源可能额外触发相机渲染
- **Copy Depth / Copy Color** — 某些 Pass 会额外触发一次 mini 渲染

如果不做防重入：
1. 第一次挂载低分辨率 RT → 正常
2. 第二次又挂载 → 覆盖第一次的结果或造成 RTHandle 抖动
3. 第三次又挂载 → 干扰其他 Pass 的正常流程

通过 `_lastCamera == camera && _lastFrame == Time.frameCount` 做简单去重 —— 同帧同相机只处理第一次回调，后续的直接 `return`。

## 踩坑记录

### 1. beginCameraRendering 被多次触发

最隐蔽的坑。日志排查发现同一相机每帧触发 **3 次** `beginCameraRendering`：

```
beginCameraRendering: Camera, origSize=1920x1080
beginCameraRendering: Camera, origSize=192x108   ← 又来了！
beginCameraRendering: Camera, origSize=19x10     ← 第三次！
```

原因：深度预通道、阴影贴图渲染等都会独立触发，且因每次设置 `camera.targetTexture` 后 `pixelWidth` 改变，下一次计算 `pixelWidth / pixelSize` 会在**已缩小**的分辨率上再次除以 `pixelSize`，RT 被指数级缩小到 1×1。

**修复**：
- 用 `Screen.width / pixelSize` 替代 `camera.pixelWidth / pixelSize`，数值恒定
- 加 `_lastCamera == camera && _lastFrame == Time.frameCount` 同帧同相机防重入

### 2. 升采样画面上下颠倒

`Blitter.BlitCameraTexture` 从 RenderTexture 到 Backbuffer 时，不同图形 API 的 UV 原点方向不一致（D3D 左上、OpenGL 左下），导致画面翻转。

**修复**：在 scaleBias 参数中设置 `Vector4(1, -1, 0, 1)` 翻转 Y 轴。

### 3. Hierarchy 点击 Camera 后 Scene/Game 视图异常

点击 Hierarchy 中的 Camera GameObject 时，Unity 会渲染该相机的**预览缩略图**。预览使用相机的 `targetTexture`（已绑定预览 RT），我们的回调又把它劫持为 `_smallRT`，导致预览损坏，进而影响编辑器渲染状态。

**修复**：
- `camera.targetTexture != null` 时跳过——预览渲染自带 RT，不干预
- `ShouldApply()` 限制只作用于 `CameraType.Game` / `CameraType.VR`，不含 `Preview` / `SceneView` / `Reflection`

## 帧调试器验证

改造前后帧调试器对比：

```
# 旧方案（总 23 事件）
18: .../Pixelate          ← 降采样
19: .../Pixelate          ← 升采样（中间阶段）

# 新方案（总 26 事件）
24: .../PixelateUpscale   ← 唯一 Blit（帧末尾）
25: UGUI.RenderOverlays   ← UI 不受影响
```

新方案中所有 Opaque → Transparent → PostProcessing 渲染都在小 RT 上进行，不再有中途的降采样 pass。`PixelateUpscale` 位于 `AfterRendering`，在所有渲染完成之后、UI Overlay 之前，位置正确。

## 总结

预缩放方案的核心在于抢占 URP 的渲染管线钩子——在 `beginCameraRendering` 中劫持 `targetTexture`，让 URP "以为"相机就是低分辨率的。相比后处理方案，不仅省去了一次 Blit，更重要的是将光栅化计算量降低到 `1/(pixelSize²)`（pixelSize=4 时仅为 1/16）。

实际使用中，`pixelSize` 建议范围 2~8：过小像素感不明显，过大会丢失太多细节。`applyToSceneView` 默认为 false 可避免编辑时 Scene View 的画质损失。
