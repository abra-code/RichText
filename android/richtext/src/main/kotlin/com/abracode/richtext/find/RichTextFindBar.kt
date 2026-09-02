package com.abracode.richtext.find

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp

// Port of Sources/RichText/Find/RichTextFindBar.swift - the standalone find UI (layer 3): a bar that edits a
// RichTextFindController. The host places it (a Column above the document, a top app bar slot) and shows it while
// `controller.isPresented`; on Android the reader opens it from a host affordance (an app-bar search icon that
// calls `controller.present()`), there being no Cmd-F. A host with its own search field skips the bar and sets
// `controller.query`; `RichText(find = controller)` still paints.

/** The find bar: field, "n of m", previous / next, an options menu and close. */
@Composable
fun RichTextFindBar(controller: RichTextFindController, modifier: Modifier = Modifier, placeholder: String = "Find") {
    val focusRequester = remember { FocusRequester() }
    var menuOpen by remember { mutableStateOf(false) }
    // Focus when a present(focus = true) asked for it and no bar has honored that request yet: a repeat request
    // while the bar is open puts the reader back in the field, a host-driven present leaves focus in the host's field.
    LaunchedEffect(controller.focusRequests) {
        if (controller.focusRequests != controller.focusHonored) {
            controller.markFocusHonored()
            focusRequester.requestFocus()
        }
    }
    Surface(color = MaterialTheme.colorScheme.surfaceContainer, modifier = modifier.fillMaxWidth().testTag("richtext.findBar")) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Icon(Icons.Filled.Search, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
            val textStyle = MaterialTheme.typography.bodyLarge.copy(color = LocalContentColor.current)
            BasicTextField(
                value = controller.query,
                onValueChange = { controller.query = it },
                singleLine = true,
                textStyle = textStyle,
                cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                keyboardActions = KeyboardActions(onSearch = { controller.next() }),
                modifier = Modifier.weight(1f).focusRequester(focusRequester).testTag("richtext.findField"),
                decorationBox = { inner ->
                    if (controller.query.isEmpty()) {
                        Text(placeholder, style = textStyle, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    inner()
                },
            )
            Text(
                controller.summary,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                modifier = Modifier.testTag("richtext.findSummary"),
            )
            IconButton(onClick = { controller.previous() }, enabled = controller.ranges.isNotEmpty()) {
                Icon(Icons.Filled.KeyboardArrowUp, contentDescription = "Previous match")
            }
            IconButton(onClick = { controller.next() }, enabled = controller.ranges.isNotEmpty()) {
                Icon(Icons.Filled.KeyboardArrowDown, contentDescription = "Next match")
            }
            IconButton(onClick = { menuOpen = true }) {
                Icon(Icons.Filled.MoreVert, contentDescription = "Find options")
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    OptionItem("Match case", controller.options.caseSensitive) {
                        controller.options = controller.options.copy(caseSensitive = it)
                    }
                    OptionItem("Whole words", controller.options.wholeWord) {
                        controller.options = controller.options.copy(wholeWord = it)
                    }
                    OptionItem("Match diacritics", controller.options.diacriticSensitive) {
                        controller.options = controller.options.copy(diacriticSensitive = it)
                    }
                    OptionItem("Regular expression", controller.options.regularExpression) {
                        controller.options = controller.options.copy(regularExpression = it)
                    }
                }
            }
            IconButton(onClick = { controller.dismiss() }) {
                Icon(Icons.Filled.Close, contentDescription = "Close find")
            }
        }
    }
}

@Composable
internal fun OptionItem(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    DropdownMenuItem(
        text = { Text(label) },
        leadingIcon = { Checkbox(checked = checked, onCheckedChange = null) },
        onClick = { onChange(!checked) },
    )
}
