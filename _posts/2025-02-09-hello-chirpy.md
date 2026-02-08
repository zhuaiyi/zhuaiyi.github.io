---
title: 欢迎使用 Chirpy
date: 2025-02-09 14:00:00 +0800
categories: [随笔]
tags: [chirpy, jekyll, 博客]
---

这是你的第一篇示例文章，用来说明 Chirpy 主题下的写作方式。

## 为什么选 Chirpy

Chirpy 是一个**以文字为中心**的 Jekyll 主题，适合写技术笔记和生活随笔。你已经在 `_config.yml` 里配置好了语言、时区和站点信息，接下来只需要在 `_posts` 目录按「日期-标题」的格式新建 Markdown 文件即可。

## 写作格式说明

每篇文章开头需要一段 **Front Matter**（用 `---` 包起来），例如：

- **title**：文章标题
- **date**：发布时间（建议带时区，如 `+0800`）
- **categories**：分类，可多个
- **tags**：标签，方便归档和检索

正文用 **Markdown** 写就行，支持标题、列表、代码块、图片等。

## 一段示例代码

```python
def hello_chirpy():
    print("Hello, Chirpy!")
```

## 接下来可以做什么

1. **改这篇内容**：直接编辑本文件，保存后本地运行 `bundle exec jekyll serve` 预览。
2. **写新文章**：在 `_posts` 里新建类似 `2025-02-10-你的标题.md` 的文件，复制上面的 Front Matter 再改标题、日期和正文。
3. **推送到 GitHub**：提交并 push 后，若已开启 GitHub Actions，站点会自动部署到 `https://zhuaiyi.github.io`。

祝你写博客愉快。
