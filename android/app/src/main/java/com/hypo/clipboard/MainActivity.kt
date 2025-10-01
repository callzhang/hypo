package com.hypo.clipboard

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import com.hypo.clipboard.service.ClipboardSyncService
import com.hypo.clipboard.ui.history.HistoryRoute
import com.hypo.clipboard.ui.history.HistoryViewModel
import com.hypo.clipboard.ui.theme.HypoTheme
import dagger.hilt.android.AndroidEntryPoint

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    private val viewModel: HistoryViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startService(Intent(this, ClipboardSyncService::class.java))

        setContent {
            HypoTheme {
                HistoryRoute(viewModel = viewModel)
            }
        }
    }
}
