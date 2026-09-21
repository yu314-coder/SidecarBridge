# Touch keyboard redesign

Replaced the equal-width letter strips with staggered QWERTY rows, side Shift/Backspace, and a wide Space key. Numbers/symbols use the 123 page. Tab and held modifiers remain above the letters; language switching remains beside Space, with full input-source cycling on Special. Hide is now a single header icon. The drawer is hidden while typing.

The panel caps at 880 x 380 points rather than 1100 x 540. Letter rows retain 48-point height; overflow scrolls. The full viewer preview exposed excess bottom space that component-size tests alone did not catch.

Composition skill output:
```json
{"composition_state":{"grid":"staggered QWERTY modular rows","primary_anchor":"letter block","secondary_anchor":"wide space key","tertiary_elements":"mode and hide header","panel_max_points":[880,380],"key_row_height":48,"negative_space":"removed footer and unused lower panel","overlap_rule":"hide control drawer during typing"}}
```

Validation: iOS simulator build and keyboard layout/mapping tests. Existing iPad simulator used with Debug-only disconnected viewer fixture; physical typing has not been validated. No release upload in this change.
