# Hypo Commercialization & Research Plan

## 1. Market Research Summary

Our analysis of the cross-platform clipboard market reveals a significant gap for a **secure, reliable, and modern** solution.

| Competitor | Primary Weakness | Market Opportunity |
| :--- | :--- | :--- |
| **KDE Connect** | Unreliable Android background sync; Clunky UI. | Build a "native-feeling" app that just works. |
| **Pushbullet** | Expensive ($4.99/mo); Privacy concerns (not E2E). | Undercut price + Offer E2E Encryption. |
| **Join** | Steep learning curve; Complex setup. | Focus on "Zero Config" simplicity. |
| **Alt-C** | Text only; Manual hotkeys. | Offer seamless media/file sync. |

**The Hypo Opportunity**: Users want the features of Pushbullet (seamless universal copy paste) with the privacy of Signal and the price of a utility app.

## 2. Value Proposition (USP)

Hypo's unique selling proposition is built on three pillars:

1.  **Privacy First**: E2E Encryption (AES-256-GCM) is enabled by default. Unlike competitors, we **cannot** see user clipboards.
2.  **Reliability**: Focus on a robust "Send to Hypo" workflow. While Android inhibits background clipboard monitoring, Hypo optimizes the sharing flow (Quick Settings tile / Share Sheet) to be faster and more reliable than competitors' clunky implementations.
3.  **Modern Native UI**: Built with SwiftUI (macOS) and Jetpack Compose (Android) for a lightweight, battery-efficient, and premium feel.

## 3. Commercialization Strategy

We will adopt a **"Privacy First, Bandwidth Paid"** Freemium model.

### The Philosophy
*   **Privacy is a Right**: Security features (Encryption, LAN Sync) are free. We do not charge for safety.
*   **Bandwidth is a Commodity**: Features that cost server resources (Cloud Storage, Large File Transfer) are paid.

### Tier Breakdown

#### **Free Tier (The "Daily Driver")**
*   **LAN Sync**: **Unlimited**. Sync text, images, and files freely when devices are on the same WiFi (Home/Office).
*   **Cloud Text Sync**: **Unlimited** (or generous quota, e.g., 50/day). Lightweight text syncing over 4G/5G.
*   **Cloud Media Quota**: **10 Items / Day**. Enough for occasional emergency use ("I left my phone at home"), but not for power users.
*   **Encryption**: Included.

#### **Pro Tier ($0.99/mo or $9.99/yr)**
*   **Cloud Sync**: **Unlimited** text, images, and files.
*   **File Size Cap**: Increased to 50MB (vs 10MB Free).
*   **Cloud History**: Encrypted backup of clipboard history across devices.
*   **Priority Support**: Dedicated channel.

### Pricing Justification
*   **Hypo ($0.99/mo)** vs. **Pushbullet ($4.99/mo)**.
*   We significantly undercut the market leader while offering superior privacy.
*   $0.99/mo covers the AWS/Fly.io bandwidth costs for file relaying while remaining a "brainless" impulse buy for users.

## 4. Go-to-Market Plan

### Phase 1: Soft Launch (Current)
*   **Target**: Developers, Open Source enthusiasts.
*   **Channel**: GitHub, Reddit (r/androidapps, r/macapps), Hacker News.
*   **Message**: "The Open Source, E2E Encrypted Alternative to Pushbullet."

### Phase 2: Public Beta & Monetization
*   **Action**: Introduce Paid Tier.
*   **Feature**: "Cloud File Sync" as the flagship Pro feature.
*   **In-App Upsell**: "File too large for free cloud sync? Sync via LAN for free, or upgrade to Pro for cellular sync." — **This is a friendly upsell that reminds them LAN is free.**

### Phase 3: Growth
*   **Target**: General Power Users.
*   **Partnerships**: Tech YouTubers, Productivity Bloggers.
*   **Keywords**: "Universal Control for Android", "AirDrop for Text".

## 5. Risk Assessment

*   **Server Costs**: Mitigated by the "Bandwidth Paid" model. Free users primarily use LAN (zero cost) or Text (negligible cost).
*   **Abuse**: Rate limits on the Free tier (10 media items/day) prevents abuse of the relay server.
*   **Competition**: Open source nature means clones may appear. Defensive moat is **brand trust** and **reliability** (hard problems like Android background service).
