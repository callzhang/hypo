package com.hypo.clipboard

import android.app.Application
import android.util.Log
import dagger.hilt.android.HiltAndroidApp
import io.sentry.android.core.SentryAndroid
import io.sentry.Sentry

@HiltAndroidApp
class HypoApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        
        // Initialize Sentry for crash reporting
        SentryAndroid.init(this) { options ->
            options.dsn = "https://65a630888bf49a147b5db985abec69f4@o4508254593875968.ingest.us.sentry.io/4510377103261696"
            // Set tracesSampleRate to 1.0 to capture 100% of transactions for tracing.
            // We recommend adjusting this value in production.
            options.tracesSampleRate = 1.0
            // When first trying Sentry it's good to see what the SDK is doing:
            options.isDebug = true
            options.environment = if (com.hypo.clipboard.BuildConfig.DEBUG) "debug" else "production"
        }
    }
}
