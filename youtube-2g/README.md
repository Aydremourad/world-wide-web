# YouTube 2G: card-free Render deployment

Prepared for the original YouTube app on a jailbroken iPhone 2G running iPhone OS 3.1.3.

[Deploy the prepared free service](https://render.com/deploy?repo=https://github.com/Aydremourad/world-wide-web/tree/youtube-2g-server)

Render hosts the backend. A computer does not need to remain running. The Blueprint explicitly selects **Free**, creates one web service, and creates no paid disks or databases. Leave the Render account without a payment method.

## 1. Create the free server

Use a modern browser for this part, on a computer or newer phone.

1. Open the deployment link above.
2. Sign up or sign in to Render. Using your GitHub account is the simplest option. If prompted for a workspace plan, use **Hobby**, the free workspace plan.
3. If GitHub asks for repository access, select `Aydremourad/world-wide-web`.
4. On the deployment review screen, confirm the service is `youtube-2g` and its compute plan is **Free / $0**. Click the deployment/apply button. Do not choose a paid plan or add a card.
5. Wait until the service says **Live**. The first build can take several minutes.
6. Open the service and copy its public URL. It will resemble `https://youtube-2g-xxxx.onrender.com`. Use the actual URL Render gives you, not this example.
7. Open that URL. You should see **YouTube 2G** and **The server is running**.

No terminal commands, Oracle VM, API key, or YouTube login are needed for this deployment.

If the shortcut does not select the branch correctly, use Render's **New → Blueprint**, connect `world-wide-web`, choose branch `youtube-2g-server`, and use the root `render.yaml`. Review the Free plan and apply it. Do not deploy the repository's `main` branch.

## 2. Enable modern HTTPS on the 2G

Render redirects HTTP to HTTPS, so the old phone needs TLSFix and current root certificates.

1. On the 2G, open **Cydia → Manage → Sources → Edit → Add**.
2. Add `http://cydia.skyglow.es/`.
3. Search for **TLSFix**, select the package from Skyglow, and install it. The checked package version is **1.1**. Let Cydia install its MobileSubstrate dependency if needed.
4. Reboot the phone.
5. In the phone's Safari, open [the unsigned root certificate bundle](http://tlsroot.litten.ca/beeg.unsigned.mobileconfig). This HTTP download was checked and does not require modern HTTPS to reach it. Select **Install** on the profile screen and complete the prompts. The signed bundle on the website is labeled iOS 5+, so use the unsigned bundle for OS 3.
6. Reboot again. Ensure the phone's date and time are correct.
7. Open your actual Render server URL in Safari on the 2G. Wait for the server page to load.
8. Tap **Play compatibility test**. You should see an eight-second “YouTube 2G / Playback test” clip.

This test checks the phone's connection and playback without contacting YouTube. If the page or test clip fails, resolve that before changing the YouTube app configuration.

TLSFix's author documents support for iPhone OS 2 through iOS 9, including ARMv6 builds. Physical playback on your 2G still needs this test.

## 3. Point the original YouTube app at the server

### If TubeRepair is already installed

1. Open **Settings → TubeRepair**.
2. Set **Custom URL** (sometimes called the endpoint) to your complete Render URL, including `https://`.
3. Reboot the 2G.
4. Open your server page in Safari and wait until it loads.
5. Open the original YouTube app and search for a short video.

### If TubeRepair is not installed

The checked Skyglow package index currently contains TLSFix but **does not contain TubeRepair**. Do not spend time searching that source for TubeRepair. The following preference-file method is an **experimental fallback** based on the public TubeRepair client's source; it has not been proven to replace every hook on OS 3.

1. On your computer, open your Render server page and click **Download iPhone configuration file**. Keep the filename `com.apple.youtubeframework.plist` exactly as downloaded. If the browser appends `.txt`, remove that extra extension.
2. Connect the jailbroken 2G by USB and open iFunBox.
3. Open **Raw File System** and navigate to `/var/mobile/Library/Preferences/`.
4. If `com.apple.youtubeframework.plist` already exists, copy it to your computer as a backup before replacing it.
5. Copy the downloaded configuration file into that folder.
6. Reboot the phone and disconnect USB.
7. Open your server page in Safari, wait for it to load, then try the original YouTube app.

The downloaded file is generated for your real server hostname. You do not need to edit its contents. If the app still contacts the old YouTube servers, this fallback is insufficient and a compatible client tweak is still needed. Do not repeatedly reinstall the server to fix that phone-side issue. Restore the backed-up plist if you want to undo the change; if the file did not exist before, delete only the file you added and reboot.

After initial setup, the computer can be turned off.

## 4. Use it

1. On the 2G, open your server URL in Safari and let the page finish loading. Bookmark it for later.
2. Open YouTube and start with a video under one minute long.
3. The first tap may play a **Preparing video** clip. Close that clip, wait a few minutes, and tap the same video again. Free Render CPU is limited, so longer videos take longer.
4. Once ready, the server sends the converted MP4. The Render deployment limits videos to **10 minutes** and converts one at a time.

No Mac or home computer runs the server. The phone only needs an Internet connection after setup.

## If something fails

| What happens | What to do |
| --- | --- |
| Render asks for payment | Keep Hobby workspace + Free compute. Do not enter a card or approve a paid service. If those options are unavailable for your account, stop there and report the exact prompt. |
| Render build fails | Open the service's **Logs** and copy the last error lines. The Docker image has not been built on Render yet; the first deployment is the cloud check. |
| Safari cannot open the server | Check TLSFix, installed root bundle, correct date/time, and the exact URL. Wait about a minute in case the server is waking. |
| Safari page loads but test video does not | The remaining issue is phone playback/HTTPS compatibility, not a YouTube download. Report that exact result. |
| Test video works but YouTube app cannot connect | Recheck the TubeRepair URL or copied plist and reboot. A working Safari test does not prove the preference-only fallback supplies every native-app hook. |
| “Preparing video” persists | Check `YOUR-SERVER-URL/status/VIDEO_ID` in a modern browser. `ready` means it finished; `preparing` means keep waiting; `failed` means inspect Render logs or try a different short public video. The video ID is the 11-character value after `v=` in a YouTube link. |
| “Video unavailable” | Try another short public video. YouTube may block downloads from the hosting provider's IP. The backend does not guarantee access to every video. |
| Previously ready video prepares again | Normal after Render sleeps or restarts: its free filesystem discards cached videos. |

## What has been checked

- Ten local tests pass, including XML feeds, HTTPS URLs behind Render's proxy, byte ranges, phone configuration, queue limits, failure cleanup, and a real synthetic FFmpeg conversion.
- The Blueprint is validated against Render's official JSON Schema.
- The Deno release used by the Dockerfile exists, and the dependencies are pinned.
- The HTTP root certificate bundle download returns successfully.
- The Docker image has **not** yet been built on Render, and live YouTube downloads and original-app playback have **not** been demonstrated on a physical 2G.

The prepared server is a testable deployment candidate. Free Render has only 0.1 CPU and 512 MB RAM. It sleeps after 15 idle minutes, wakes in about one minute, and loses cached videos when it sleeps or restarts. Usage limits and unusually high outbound activity can suspend it. With no payment method, documented bandwidth overages suspend free services rather than charging you. Google account sign-in, live streams, comments, and server-side playlists are not implemented.

## Primary sources

- [Render: first deployment, no payment required](https://render.com/docs/your-first-deploy)
- [Render: no credit card required](https://render.com/articles/platforms-with-a-real-free-tier-for-developers-in-2026)
- [Render free service limits](https://render.com/docs/free)
- [Render HTTPS redirects](https://render.com/docs/tls)
- [Render deploy shortcut and branch selection](https://render.com/docs/deploy-to-render)
- [TLSFix support and installation](https://github.com/nfzerox/TLSFix)
- [Root certificate bundles](http://tlsroot.litten.ca/)
- [TubeRepair client source](https://github.com/ObscureMosquito/TubeRepair-Client)
- [Classic server templates and original credits](https://github.com/ShahAndI123/Modified-Tuberepair-for-ios-2-6-built-in-YT-best-for-pre-iphone-4)

Research checked October 1, 2026. This guide replaces the earlier Oracle setup directions.
