#!/bin/bash
# GPL-3.0; companion to the YouTube 2G server.
# Exports a disposable YouTube browser session using upstream yt-dlp.
# No browser extension, Python installation, or server code change is needed.

filter_youtube_cookies() {
    /usr/bin/awk -F '\t' '
        BEGIN { print "# Netscape HTTP Cookie File" }
        {
            domain = tolower($1)
            sub(/^#httponly_/, "", domain)
            sub(/^\./, "", domain)
            if (NF != 7 || (domain != "youtube.com" && domain !~ /\.youtube\.com$/))
                next
            print $0
            count++
            if ($6 ~ /^(SAPISID|__Secure-1PAPISID|__Secure-3PAPISID|SID|__Secure-1PSID|__Secure-3PSID)$/ && $7 != "")
                authenticated = 1
        }
        END { if (!count || !authenticated) exit 3 }
    ' "$1"
}

cookie_helper_work=""
cookie_helper_chrome_pid=""

stop_cookie_helper_chrome() {
    if [[ -n "$cookie_helper_chrome_pid" ]]; then
        kill -TERM "$cookie_helper_chrome_pid" 2>/dev/null || true
        # Shut down only the disposable Chrome process launched by this script.
        for counter in {1..30}; do
            if ! kill -0 "$cookie_helper_chrome_pid" 2>/dev/null; then break; fi
            /bin/sleep 0.1
        done
        if kill -0 "$cookie_helper_chrome_pid" 2>/dev/null; then
            kill -KILL "$cookie_helper_chrome_pid" 2>/dev/null || true
        fi
        wait "$cookie_helper_chrome_pid" 2>/dev/null || true
        cookie_helper_chrome_pid=""
    fi
}

cleanup_cookie_helper() {
    stop_cookie_helper_chrome
    if [[ -n "$cookie_helper_work" ]]; then
        /bin/rm -rf "$cookie_helper_work"
    fi
}

main() {
    set -euo pipefail
    umask 077
    if [[ "$(uname -s)" != "Darwin" ]]; then
        printf '%s\n' "This helper runs on your Mac."
        exit 1
    fi
    chrome_binary="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    if [[ ! -x "$chrome_binary" ]]; then
        chrome_binary="$HOME/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    fi
    if [[ ! -x "$chrome_binary" ]]; then
        printf '%s\n' "Google Chrome could not be found in Applications."
        exit 1
    fi

    cookie_helper_work="$(/usr/bin/mktemp -d -t youtube2g-export)"
    trap cleanup_cookie_helper EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    printf '%s\n' "Downloading the official cookie-export tool..."
    /usr/bin/curl --fail --location --silent --show-error --retry 2 \
        --connect-timeout 15 --max-time 180 \
        "https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp_macos" \
        -o "$cookie_helper_work/yt-dlp"
    checksum="$(/usr/bin/shasum -a 256 "$cookie_helper_work/yt-dlp" | /usr/bin/awk '{print $1}')"
    if [[ "$checksum" != "0f192b7ec147ab6288885d6351d9ab67367640029b4377576ef46dd79cf7b202" ]]; then
        printf '%s\n' "The download did not match its official checksum. Please run the helper again."
        exit 1
    fi
    /bin/chmod 700 "$cookie_helper_work/yt-dlp"

    printf '\n%s\n' "A temporary YouTube-only Chrome window will open."
    printf '%s\n' "Sign in to YouTube in that window, preferably with a spare account."
    printf '%s\n' "Wait until YouTube shows your account picture. Keep the window open."
    printf '%s\n' "Then return to THIS Terminal window and press Return."
    printf '%s\n' "The helper will close its temporary window after exporting the session."
    "$chrome_binary" \
        --user-data-dir="$cookie_helper_work/chrome" \
        --no-first-run --no-default-browser-check --disable-sync \
        "https://www.youtube.com/" >"$cookie_helper_work/chrome.log" 2>&1 &
    cookie_helper_chrome_pid=$!
    IFS= read -r reply
    stop_cookie_helper_chrome

    printf '\n%s\n' "Exporting YouTube cookies locally..."
    printf '%s\n' "If macOS asks to access Chrome Safe Storage, choose Allow."
    # Listing local capabilities creates and closes YoutubeDL without contacting
    # YouTube. Closing saves the browser cookie jar. Only this temporary profile
    # is read, and the following filter retains youtube.com domains exclusively.
    if ! "$cookie_helper_work/yt-dlp" \
        --ignore-config --no-warnings --no-progress \
        --cookies-from-browser "chrome:$cookie_helper_work/chrome" \
        --cookies "$cookie_helper_work/all-cookies.txt" \
        --list-impersonate-targets >"$cookie_helper_work/export.log" 2>&1; then
        printf '%s\n' "Export failed. Check that Chrome Safe Storage access was allowed, then run the helper again."
        printf '%s\n' "No cookies have been copied."
        exit 1
    fi
    if ! filter_youtube_cookies "$cookie_helper_work/all-cookies.txt" >"$cookie_helper_work/youtube-cookies.txt"; then
        printf '%s\n' "A signed-in YouTube session was not found. Run the helper again and finish signing in before pressing Return."
        exit 1
    fi
    /bin/mkdir -p "$HOME/Downloads"
    destination="$HOME/Downloads/youtube-cookies-$(/bin/date +%Y%m%d-%H%M%S).txt"
    /bin/cp "$cookie_helper_work/youtube-cookies.txt" "$destination"
    /bin/chmod 600 "$destination"
    /usr/bin/pbcopy <"$destination"
    printf '\n%s\n' "READY: YouTube cookies are copied to your clipboard."
    printf '%s\n' "Open Render -> youtube-2g -> Environment -> Secret Files."
    printf '%s\n' "Add a secret file named youtube-cookies.txt and paste into Contents."
    printf '%s\n' "Save/deploy, wait for Live, then tell me. Keep the cookies private."
    printf 'A private copy was saved at: %s\n' "$destination"
    /usr/bin/open "https://dashboard.render.com/" || true
}

if [[ "$BASH_SOURCE" == "$0" ]]; then
    main "$@"
fi
