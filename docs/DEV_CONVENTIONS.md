# 开发约定：让界面“能被自动测试稳定地找到”

给开发（人或 AI）。**新增页面时顺手做，一个控件几秒钟**；不做的话，测试只能靠文案和位置找控件，文案一改、换语言就全红。

## 1. 给关键控件加固定标识
“关键控件”= 自动测试要点击、输入、断言的东西：按钮、输入框、列表、列表项、页面标题、加载完成标志、提示/错误文字。

### Flutter：`Semantics(identifier:)`
```dart
Semantics(
  identifier: 'login_submit',
  child: ElevatedButton(onPressed: _submit, child: Text(l10n.login)),
)
```
它会在 Android 的元素树里变成 `resource-id`，Maestro 里用 `id: "login_submit"` 选择。（套件已在 Flutter 项目上验证过 `id:` 选择器可用。）

### Jetpack Compose：`testTag` + `testTagsAsResourceId`
```kotlin
// 需要的导入（在套件验证的项目里是这几行；项目用的 Compose 版本不同时，注解要求可能不同，未验证）：
// import androidx.compose.ui.ExperimentalComposeUiApi
// import androidx.compose.ui.Modifier
// import androidx.compose.ui.platform.testTag
// import androidx.compose.ui.semantics.semantics
// import androidx.compose.ui.semantics.testTagsAsResourceId

// 页面最外层（只需要一次，建议放在根 Composable 或 Activity 的 setContent 里）
@OptIn(ExperimentalComposeUiApi::class)   // 加在用到 testTagsAsResourceId 的函数上
Box(Modifier.semantics { testTagsAsResourceId = true }) {
    // ……整个界面
}
// 控件
FloatingActionButton(onClick = onAdd, modifier = Modifier.testTag("add_task_fab")) { … }
```
Compose 默认**没有** `resource-id`，不加这两样，`id:` 选择器用不了（实测，见 FINDINGS M28）。

### 传统 View（XML）
用 `android:id`，`id: "text_note_view"` 不带包名前缀即可匹配。已有的 id 不要为了“整洁”随意改名。

### 弹窗、底部弹层、确认框（**未验证，写代码时先自查**）
确认框里的按钮、标题和提示文字同样是关键控件，也要加标识。但 Compose 的 `Dialog` / `AlertDialog` / `ModalBottomSheet` 往往在**独立的窗口**里，页面根上的 `testTagsAsResourceId` **不一定覆盖它**；Flutter 的对话框在路由层，需要把 `Semantics(identifier:)` 加在对话框内的控件上。套件**没有**在弹窗上验证过——加完后用 `maestro hierarchy`（弹窗打开时）确认 id 真的出现了；没出现就在弹窗内容自己的根上再加一次 `testTagsAsResourceId`，并在 PR 里写明结果。

### “状态”怎么暴露（如“已取消”“已收藏”）
**id 保持固定，状态靠文字或描述断言**：例如订单状态文字控件固定为 `order_status`，测试断言它的文字是“已取消”（或在无障碍描述里放状态）。**不要**让 id 随状态变化（`order_status_cancelled`），否则一个控件要换多个 id，换文案/语言还要同步。需要区分“选中/未选中”时，优先用文字/描述；`selected:`/`checked:` 选择器在 Flutter 自绘控件上不可用（FINDINGS M14）。

## 2. 命名规则
- 小写加下划线：`<页面>_<控件>`，如 `login_submit`、`cart_item_remove`。
- **不随文案、语言、主题变化**；不含时间、随机数、用户数据。
- 同一屏里不要重复。列表里的每一项用稳定的业务标识拼接（如 `order_item_<订单号>`），不要用显示出来的文字。
- 一旦写进测试，改名要同步改用例。**改 id 等于改接口**，PR 里要写明。
- 每个页面加一个“加载完成”标志（如 `home_ready`，数据显示出来之后才出现），测试等它，而不是等固定秒数。

## 3. 让启动状态确定
自动测试最常见的偶发失败，不是脚本写错，而是 App 每次启动停在不同的地方（上次留下的页面、突然弹出的营销弹窗）。请开发做到：
1. **冷启动一定落在确定的页面**（如首页）；测试包提供办法恢复到“新装第一次打开”的状态。
2. **测试包提供开关，关掉会干扰的东西**：启动弹窗、营销弹窗、新手引导、评分提示、权限预弹窗、强制更新。开关可以是 `BuildConfig` / 环境变量 / 启动参数，**只在测试包生效，正式包不能被外部打开**。
3. **测试包连固定的测试环境**（接口地址写在测试包里，或通过启动参数指定），不要依赖设备上手工选的环境。
4. 启动后不依赖“当前时间 / 随机内容”显示关键文字；必须有时，给出固定的测试数据。
5. 动画、轮播、自动滚动在测试包里可关闭（或至少不影响关键控件的位置）。

## 4. 不要做的事
- 不要在测试包里“绕过”验证码、设备校验、风控来方便测试；这类放行由后端对**测试账号**做（见 [TEST_ENV_REQUIREMENTS.md](TEST_ENV_REQUIREMENTS.md)）。
- 不要把账号、密码、内部地址写进仓库里的测试文件。
- 不要为了让测试通过去改产品逻辑；发现问题就报告。

## 5. 提交前自查（30 秒）
- [ ] 新页面的关键控件都有固定标识
- [ ] `maestro hierarchy`（或 Maestro Studio）里能看到这些 id
- [ ] 冷启动落点确定，没有会挡住界面的弹窗（测试开关已关）
- [ ] 加了“加载完成”标志
- [ ] 没有改动已被用例使用的老 id；改了就同步改了用例
