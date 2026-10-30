package org.orbtchess.orbt.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.MediumFlexibleTopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.unit.dp
import androidx.navigationevent.NavigationEventInfo
import androidx.navigationevent.compose.NavigationBackHandler
import androidx.navigationevent.compose.rememberNavigationEventState
import java.text.Collator
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import orbt.app.generated.resources.Res
import org.orbtchess.orbt.ui.components.Symbols

/**
 * About ORBT Chess (`Acknowledgements.swift`, the Lichess app's About screen): the app's pages,
 * its source and licenses, then every license the app ships under and its text. Full window;
 * the licenses and a license's text are pages of this screen, going back to it.
 */
@OptIn(ExperimentalComposeUiApi::class)
@Composable
fun AcknowledgementsScreen(onBack: () -> Unit, modifier: Modifier = Modifier) {
    var page by remember { mutableStateOf<Page>(Page.About) }
    val acknowledgements by produceState(Acknowledgements.empty) {
        value = withContext(Dispatchers.IO) {
            runCatching { Acknowledgements.decode(Res.readBytes("files/Acknowledgements.json")) }
                .getOrDefault(Acknowledgements.empty)
        }
    }
    NavigationBackHandler(
        rememberNavigationEventState(NavigationEventInfo.None),
        isBackEnabled = page != Page.About,
        onBackCompleted = { page = page.parent },
    )
    when (val current = page) {
        Page.About -> AboutPage(onBack, modifier) { page = Page.Licenses }
        Page.Licenses -> LicensesPage(acknowledgements, { page = Page.About }, modifier) { page = Page.Text(it) }
        is Page.Text -> LicenseTextPage(current.entry, { page = Page.Licenses }, modifier)
    }
}

private sealed interface Page {
    data object About : Page
    data object Licenses : Page
    data class Text(val entry: LicenseEntry) : Page

    val parent: Page
        get() = when (this) {
            About, Licenses -> About
            is Text -> Licenses
        }
}

private data class LicenseEntry(val id: String, val name: String, val text: String, val attribution: String? = null)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Page(title: String, onBack: () -> Unit, modifier: Modifier, content: @Composable (Modifier) -> Unit) {
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    Scaffold(
        modifier = modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        topBar = {
            MediumFlexibleTopAppBar(
                title = { Text(title) },
                scrollBehavior = scrollBehavior,
                navigationIcon = {
                    IconButton(onClick = onBack, shapes = IconButtonDefaults.shapes()) { Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back") }
                },
            )
        },
    ) { padding -> content(Modifier.fillMaxSize().padding(padding)) }
}

/** The app's pages, its source and licenses. */
@Composable
private fun AboutPage(onBack: () -> Unit, modifier: Modifier, openLicenses: () -> Unit) {
    val uri = LocalUriHandler.current
    val version = appVersion()
    Page("About", onBack, modifier) { inner ->
        Column(inner.verticalScroll(rememberScrollState())) {
            for ((title, url) in listOf("Website" to AppLinks.WEBSITE, "Support" to AppLinks.SUPPORT, "Privacy Policy" to AppLinks.PRIVACY)) {
                LinkRow(title) { uri.openUri(url) }
            }
            HorizontalDivider(Modifier.padding(vertical = 8.dp))
            LinkRow("Source Code") { uri.openUri(AppLinks.SOURCE) }
            ListItem(
                onClick = openLicenses,
            ) { Text("Licenses") }
            Text(
                "Version $version. ORBT Chess is free software: you can share and change it under the GNU AGPL 3.0 or later.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )
        }
    }
}

@Composable
private fun LinkRow(title: String, onClick: () -> Unit) {
    ListItem(
        onClick = onClick,
        trailingContent = { Icon(Symbols.openInBrowser, contentDescription = "Opens in the browser") },
    ) { Text(title) }
}

/**
 * Every license the app ships under, one row each (Flutter's license page, which the Lichess
 * app shows): ORBT Chess first, then the components, crates and libraries by name.
 */
@Composable
private fun LicensesPage(acknowledgements: Acknowledgements, onBack: () -> Unit, modifier: Modifier, open: (LicenseEntry) -> Unit) {
    val app = LicenseEntry("ORBT Chess", "ORBT Chess", acknowledgements.licenses["AGPL-3.0"] ?: "")
    val entries = remember(acknowledgements) {
        val components = Component.all.map {
            LicenseEntry(it.name, it.name, acknowledgements.licenses[it.text] ?: "", it.attribution)
        }
        val crates = (acknowledgements.crates + acknowledgements.libraries).map {
            LicenseEntry("${it.name} ${it.version}".trim(), it.name, acknowledgements.text(it))
        }
        val collator = Collator.getInstance()
        (components + crates).sortedWith { a, b -> collator.compare(a.name, b.name) }
    }
    Page("Licenses", onBack, modifier) { inner ->
        LazyColumn(inner) {
            item { ListItem(
                onClick = { open(app) },
            ) { Text(app.name) } }
            item { HorizontalDivider(Modifier.padding(vertical = 8.dp)) }
            items(entries, key = { it.id }) { entry ->
                ListItem(
                    onClick = { open(entry) },
                ) { Text(entry.name) }
            }
        }
    }
}

@Composable
private fun LicenseTextPage(entry: LicenseEntry, onBack: () -> Unit, modifier: Modifier) {
    val text = remember(entry) { reflowed(entry.text) }
    Page(entry.name, onBack, modifier) { inner ->
        SelectionContainer(inner) {
            Column(
                Modifier.verticalScroll(rememberScrollState()).padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                entry.attribution?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
                Text(text, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}
