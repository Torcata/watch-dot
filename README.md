```text
              -=
            :#%+:
           -@%##=#%#%%%##*+-.
        :==@%%##=::....:-=*#%#=
      -%@*#%%%%#+           .=%@+.   -.
    :%@*.=+*%%%%*.             -%#:=#*+=
   +@%: .=++*%%%%=             .=#%%##*
  +@#  .*-=+++#%%%-        .-=*#**###+.
 =@#    -*=-=+++#%%-   .-+#***++*%%*+:       _____                  _
 %@:      =*=:=++*%#::+#%%++++*#%#-.@@      |_   _|__  _ __ ___ __ _| |_ __ _
:@%       :=%-.-==*%++%%#+=++*##+.  #@:       | |/ _ \| '__/ __/ _` | __/ _` |
-@%     :###*##+-+*--%%%+=++*%#-    *@-       | | (_) | | | (_| (_| | || (_| |
.@@.    *#**#*+--+:-%%#*==+#%*.     %@:       |_|\___/|_|  \___\__,_|\__\__,_|
 *@+    =*%*:  :#.+####*+*#%=      -@#
 .%@:   *%*:.-*#-=#*****+**:      :@@:
  :%@::%%-   .:-+####%#***+.     -@@:           S O F T W A R E
   .**%=        ..:---+###@%*- .*@#.
    :-*@*:            -%%##%%%*+#-
       =%@%+:.        :#**#**++**-
         .=#%%##*++++*+**++=#*%#*-
             .-=++**++-.      .
```

# Watch Dot

Talk to your ChatGPT Dot straight from your Apple Watch, even when your iPhone stays at home. Watch Dot is a native watchOS client built for cellular watches (tested on an Apple Watch Ultra 2).

> ⚠️ **Experimental project.** OpenAI doesn't offer a public API for chatting with your personal Dot. Watch Dot uses the same protocol as the desktop app, so it may stop working if OpenAI changes it.

## What it does

- **Chat directly with your Dot:** type or dictate a message, tap the arrow, and the reply arrives on your watch. It's the same conversation you see in ChatGPT.
- **Use your Dot without your iPhone:** the iPhone is only needed to sign in. After that, the watch chats and renews the session on its own, over Wi‑Fi or cellular.
- **On-demand sync:** to pull in messages sent from other devices, scroll to the bottom of the chat and swipe up.
- **Watch face complication:** a shortcut to open the chat with a single tap.

## Next Features
- **Push notifications**
- **Voice replies**

## Requirements

- Mac with Xcode and Swift 6
- iPhone running iOS 17 or later, with Developer Mode enabled
- Apple Watch running watchOS 10 or later, paired with that iPhone
- A ChatGPT account with Dot

## Installation

1. Open `WatchDot.xcodeproj` in Xcode.
2. Choose the **WatchDotPhone** scheme and your iPhone as the destination. Make sure all three targets use your signing team.
3. Press **⌘R**. This installs the iPhone app, which bundles the watch app.
4. On your iPhone, open the **Watch** app, go to the **My Watch** tab and scroll down to **Available Apps**. Tap **Install** next to Watch Dot.
   *(If automatic app install is turned on, it may already be installed.)*

To update, repeat step 3. Your session and history are kept.

## First sign-in

1. Open Watch Dot on your watch **and** on your iPhone.
2. Tap **Continuar con ChatGPT** ("Continue with ChatGPT") on either device.
3. Sign in using the browser that opens on your iPhone.
4. Wait for the watch to confirm the connection. A green dot next to your Dot's name means the session is active.

That's it: from now on you don't need your iPhone.

## Adding the complication

The Apple Watch complication gives you a handy shortcut to summon your Dot assistant.
1. Touch and hold the watch face → **Edit** → **Complications**.
2. Pick a circular or corner slot and select **Watch Dot**.
3. Press the Digital Crown to save.

## License

Free software under [GPL-3.0-only](LICENSE). Authorship and provenance in [NOTICE](NOTICE).
