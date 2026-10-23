# Cooper V2 — Folded C

保留 C 与文件夹的概念，通过折叠色面构成开放的 C，移除 V1 的系统文件夹页签和独立方块。橙色顶面与蓝色侧面、底面形成前后层次；单色时仍保留独立的 C 轮廓。

建议主色为亮靛蓝 `#485BFF`，辅助色为暖杏橙 `#FF965F`，文字色为 `#202238`。彩色生成稿包含折面明暗，并非所有像素都是色板中的纯色。

## 文件

- `cooper-v2-preview.png`：品牌、字标、macOS 图标及单色版本展示，1800 × 1160。
- `cooper-v2-mark.png`：独立标志，1254 × 1254，透明 PNG；清理了生成稿的零散透明边缘噪点。
- `cooper-v2-logo.png`：Cooper 横排字标，2400 × 800，透明 PNG。
- `cooper-v2-app-icon.png`：白色底板的 macOS 正式图标源图，1024 × 1024。
- `Cooper.icns`、`Cooper.iconset/`：macOS 图标文件及 16、32、128、256、512 pt 的 1x / 2x PNG。
- `cooper-v2-mono.png`、`cooper-v2-white.png`、`cooper-v2-blue.png`：单色、白色和纯蓝版本。
- `cooper-v2-size-check.png`：16、24、32、64、128 像素的实际缩小检查。
- `cooper-v2-generated.png`、`cooper-v2-symbol-generated.png`：原始 API 概念稿及独立标志稿。
- `cooper-v2-prompt.txt`、`cooper-v2-symbol-prompt.txt`：两次调用的完整提示词。
- `build_v2.py`：无需网络的透明边缘清理、排版与导出脚本，依赖 Python Pillow、NumPy、OpenCV 和 macOS Avenir Next 字体。

本版为栅格设计方案，没有宣称自动生成稿是可编辑矢量图。PNG 均已重新读取验证，并检查透明通道、单色外轮廓和缩小效果。16 像素下折面阴影不明显，主要依靠轮廓和双色区分。

## 参考与制作

用户指定参考 Dropbox、OneDrive、Synology Drive、Google Drive。参考的是几何构成、清晰的色块和小尺寸识别方式，不使用这些品牌的标志作为 Cooper 素材。参考图见 [Synology 官方产品页中的云盘图标组合](https://www.synology.com/en-us/products/DS124)。

使用 imagegen 技能的 CLI/API 路径，在用户指定服务 `https://api.tudoubaby.de/v1` 上调用 `gpt-image-2.5-sunburst`，一次生成概念、一轮编辑获得独立标志。这里记录的是服务商模型标识，未核实底层模型身份。凭据未保存到项目文件。

V2 已被选定为正式版本，并接入 `App/Assets.xcassets` 的 `AppIcon` 与 `CooperMark`。侧栏、首页欢迎区域、设置页共用新标志；深浅色外观均保留蓝橙色。V1 源稿作为历史方案保留，不再作为当前应用资源。

更新源图后，在项目根目录运行 `python3 scripts/update-brand-assets.py`，重新导出应用资源和本目录中的 ICNS / iconset。该脚本使用本地 PNG，不调用生图 API。
