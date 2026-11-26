# 皮肤包设计稿（Skin Pack v1.0 · 7 档）

这是已确定并接入 App 的按键皮肤设计原稿，留档备查。

## 与代码的对应关系

| 设计稿 | App 代码 |
| --- | --- |
| `skins.json` 的 7 档 token | `lib/skins.dart` 的 `kButtonSkins`（glass / frosted / system / well / ghost / row / contrast） |
| `skin-tokens.css` 的 8 个 `--cta-*` 变量 | `ButtonSkin` 的 face/stops/edge/top/bottom/blurSigma/castColor/castBlur/castOffset/fg |
| `index.html` 成品选择器 | App 内「外观 → 按钮材质」设置组（`lib/pages_glass.dart`），选择存 `morning.skin` |

## 接入记录

- v1.21.4（2026-11-25）：7 档材质接入 App，设置项入口在「我的 → 外观」
- 对比度底线 WCAG ≥ 9:1，测试见 `test/button_skins_test.dart`
- 未选择时跟随当前主题（空串 = 跟随），未知档位回退 glass
