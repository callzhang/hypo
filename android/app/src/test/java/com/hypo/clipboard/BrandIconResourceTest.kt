package com.hypo.clipboard

import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.Test
import kotlin.test.assertEquals
import org.w3c.dom.Document

class BrandIconResourceTest {
    private val drawableDirectory = File(requireNotNull(System.getProperty("hypo.drawable.dir")))

    @Test
    fun `adaptive launcher icon uses the brand gradient as its full background`() {
        val background = parseDrawable("ic_launcher_background.xml")
        val gradients = background.getElementsByTagName("gradient")

        assertEquals(1, gradients.length, "Adaptive background must own the Hypo gradient")
        assertEquals("#5EB1FF", gradients.item(0).attributes.getNamedItem("android:startColor").nodeValue)
        assertEquals("#8458FF", gradients.item(0).attributes.getNamedItem("android:endColor").nodeValue)
    }

    @Test
    fun `adaptive launcher foreground contains only the three layered Hypo ellipses`() {
        val foreground = parseDrawable("ic_launcher_foreground.xml")
        val paths = foreground.getElementsByTagName("path")

        assertEquals(0, foreground.getElementsByTagName("gradient").length)
        assertEquals(3, paths.length, "Adaptive foreground must not contain a second rounded app tile")
        repeat(paths.length) { index ->
            assertEquals(
                "#FFFFFF",
                paths.item(index).attributes.getNamedItem("android:fillColor").nodeValue
            )
        }
    }

    @Test
    fun `quick settings icon uses the same three-layer Hypo silhouette`() {
        val quickSettingsIcon = parseDrawable("ic_quick_settings.xml")
        val paths = quickSettingsIcon.getElementsByTagName("path")

        assertEquals(3, paths.length, "Tile icon must use the three Hypo layers, not a clipboard glyph")
        repeat(paths.length) { index ->
            assertEquals(
                "@android:color/white",
                paths.item(index).attributes.getNamedItem("android:fillColor").nodeValue
            )
        }
    }

    private fun parseDrawable(filename: String): Document {
        val file = File(drawableDirectory, filename)
        return DocumentBuilderFactory.newInstance()
            .newDocumentBuilder()
            .parse(file)
    }
}
