# Cooper Logo — Concept 01

> 本目录根层文件保留为 V1 历史方案。当前正式采用并接入应用的是 [V2「折叠的 C」](v2/README.md)，最新素材包为 `v2/Cooper-v2-logo-kit.zip`。

设计概念：将 Cooper 首字母 C 与打开的文件夹合并，右侧薄荷色连接块代表接入本地的云存储。适用于 Cooper 的 macOS 云存储挂载工具定位。

## 交付文件

- `cooper-brand-preview.png`：最终交付素材的品牌预览，1800 × 1160。
- `cooper-logo.svg` / `cooper-logo.png`：横排标志与 Cooper 字标；PNG 为 2420 × 800，透明背景。
- `cooper-mark.svg` / `cooper-mark.png`：独立彩色标志；PNG 为 2048 × 2048，透明背景。
- `cooper-mark-mono.svg` / `.png`：单色版本。
- `cooper-mark-white.svg` / `.png`：深色背景上使用的白色版本。
- `cooper-app-icon.svg` / `.png`：macOS 图标；PNG 为 1024 × 1024，外部留白透明。
- `Cooper.icns` / `Cooper.iconset/`：macOS 图标及对应 16、32、128、256、512 pt 的 1x / 2x PNG。
- `cooper-brand-concept.png`：API 生图原始概念稿，仅作创意参考，不是精确的最终矢量版本。
- `cooper-logo-prompt.txt`：本次生图完整提示词。
- `build_logo.py`：无需网络的素材生成脚本；依赖 macOS、Python Pillow、ImageMagick 和 iconutil。

## 颜色与排版

- 深海蓝：`#15374B`
- 薄荷青：`#67DCC3`
- 浅薄荷：`#DDF8EF`
- 预览背景：`#F5F7F6`
- 字标：Avenir Next Demi Bold。横排 SVG 保留可编辑文字，在没有此字体的设备上会使用后备字体；需要固定外观时使用 PNG，或在设计软件中将文字转为轮廓。独立标志和 App 图标 SVG 均为路径，不依赖字体。

建议标志四周至少保留其宽度的 15% 作为净空。小尺寸保留 C 形轮廓和独立连接块，不附加字标。品牌预览中的英文说明仅为展示文案。

## 制作记录

通过 imagegen 技能的 CLI/API 路径，向用户指定的 `https://api.tudoubaby.de/v1` 发出一次生图请求，使用服务商模型标识 `gpt-image-2.5-flare`。该标识是服务商提供的名称，不代表已验证的底层模型身份。

请求尺寸为 1536 × 1024；服务实际返回 1774 × 887 RGBA 图片。最终素材已按照交付尺寸重新用几何路径构建与导出，并修整了原始生成稿的小装饰和边缘细节。密钥未写入项目文件。

本次仅完成设计资产，未将图标接入 Xcode 工程或安装到应用。所有新增文件均位于当前 CooperApp 项目的 `output/imagegen/`。
