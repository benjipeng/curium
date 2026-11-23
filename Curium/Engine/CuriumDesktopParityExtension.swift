import CryptoKit
import CuriumEngineContract
import Foundation
import OSLog

/// Built-in hidden Manifest V3 extension loaded into Chromium's
/// `TrustedUnpackedExtensions` directory at startup for desktop macOS profiles.
///
/// Runs a single pass-through-first `MAIN`-world `document_start` script
/// (`desktop_parity.js`) that closes remaining iOS-to-macOS Web API surface
/// deltas only when `navigator.platform === 'MacIntel'`.
enum CuriumDesktopParityExtension {
    static let directoryName = "curium_desktop_parity"
    static let manifestVersion = "1.0.0"
    static let versionStampFileName = ".curium_version"

    /// Static RSA-2048 SubjectPublicKeyInfo (DER, base64-encoded).
    /// The corresponding private key was discarded at generation time; only this
    /// public key is embedded so Chromium derives a deterministic extension ID.
    static let publicKeyBase64 =
        "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA58ZE3HxljreLP+RM4C2O"
        + "M2Ag6qbmuMHq7U5HopBfgc6l6cRAXhvsdT14qDj1ra5IvLIMLayqemm/5mnj4sdS"
        + "e5SULFXSU65mHvgFCkHrFejpVsRIbjbw4ftBjGMnQ16Tt9lxCcreqJ3Gomi1dfh/"
        + "6B0v8nU3E15voWURoOxP3WUhluSpOS0SQOf8wHNf5l2ikEz4lrYnJ5HwS8CNrC9r"
        + "kK+wLo6ZUBzWHQ1jjhoO85wWM0Ura2sSE4wCRNKhkn8TknWT2zEOTxxtM97IkaR7"
        + "aXfVksEMq+dN6MKqoGLBjnt4qYE9hNIqwT2memjuxVgec3jPtjfGsaWtOsG88ieS"
        + "pwIDAQAB"

    static let extensionID = "igckbhkefpgcfcijbdhbkalaofkagpom"
    static let hiddenExtensionIDs: Set<String> = [extensionID]

    private static let log = Logger(subsystem: "com.appautomaton.curium", category: "desktop-parity")
    private static let retryBackoffs: [Duration] = [
        .milliseconds(200),
        .milliseconds(400),
        .milliseconds(800),
        .milliseconds(1500),
        .milliseconds(2500),
        .milliseconds(3000),
    ]

    /// Computes Chromium's 32-character `a`-`p` extension ID from a base64-encoded
    /// SubjectPublicKeyInfo DER public key (`crx_file::id_util::GenerateId`).
    static func deriveExtensionID(publicKeyBase64: String) -> String? {
        CuriumVideoPiPExtension.deriveExtensionID(publicKeyBase64: publicKeyBase64)
    }

    static var manifestJSON: String {
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "name": "Curium Desktop Parity",
            "version": manifestVersion,
            "key": publicKeyBase64,
            "content_scripts": [
                [
                    "matches": ["http://*/*", "https://*/*"],
                    "js": ["desktop_parity.js"],
                    "run_at": "document_start",
                    "world": "MAIN",
                    "all_frames": true,
                    "match_about_blank": true,
                ],
            ],
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ),
        let text = String(data: data, encoding: .utf8) else {
            preconditionFailure("CuriumDesktopParityExtension manifest serialization failed")
        }
        return text + "\n"
    }

    static let parityScript: String = #"""
(() => {
  'use strict';

  const patched = new WeakSet();

  const IOS_LEAKS = [
    '__gCrWeb',
    '_injected_gcrweb',
    '_injected_language_detection',
    '_injected_send_webkit_message',
    '_injected_translate_ios',
    'gcrweb',
    'webkitMessageHandler',
    'NDEFMessage',
    'NDEFReader',
    'NDEFReadingEvent',
    'NDEFRecord',
  ];

  const MAC_EN_US_LAYOUT = [
    ['KeyK', 'k'], ['KeyG', 'g'], ['Digit2', '2'], ['Digit0', '0'],
    ['KeyV', 'v'], ['KeyA', 'a'], ['Backquote', '`'], ['KeyL', 'l'],
    ['IntlBackslash', '\u00a7'], ['Quote', "'"], ['KeyW', 'w'], ['Digit8', '8'],
    ['KeyM', 'm'], ['KeyH', 'h'], ['Period', '.'], ['Digit7', '7'],
    ['Digit1', '1'], ['KeyP', 'p'], ['KeyD', 'd'], ['KeyF', 'f'],
    ['KeyO', 'o'], ['KeyQ', 'q'], ['KeyC', 'c'], ['KeyN', 'n'],
    ['BracketLeft', '['], ['KeyZ', 'z'], ['KeyY', 'y'], ['Digit3', '3'],
    ['Digit6', '6'], ['Digit5', '5'], ['KeyX', 'x'], ['Slash', '/'],
    ['Backslash', '\\'], ['Comma', ','], ['Minus', '-'], ['Digit4', '4'],
    ['KeyB', 'b'], ['KeyT', 't'], ['Digit9', '9'], ['KeyS', 's'],
    ['KeyI', 'i'], ['KeyU', 'u'], ['Equal', '='], ['KeyJ', 'j'],
    ['Semicolon', ';'], ['KeyR', 'r'], ['BracketRight', ']'], ['KeyE', 'e'],
  ];

  const VOICES_JSON =
    '[["","Samantha","en-US",1,1],["","Albert","en-US",1,0],["","Alice","it-IT",1,0],' +
    '["","Alva","sv-SE",1,0],["","Amélie","fr-CA",1,0],["","Amira","ms-MY",1,0],' +
    '["","Anna","de-DE",1,0],["","Bad News","en-US",1,0],["","Bahh","en-US",1,0],' +
    '["","Bells","en-US",1,0],["","Boing","en-US",1,0],["","Bubbles","en-US",1,0],' +
    '["","Carmit","he-IL",1,0],["","Cellos","en-US",1,0],["","Damayanti","id-ID",1,0],' +
    '["","Daniel","en-GB",1,0],["","Daria","bg-BG",1,0],' +
    '["","Eddy (English (United States))","en-US",1,0],["","Eddy (English (United Kingdom))","en-GB",1,0],' +
    '["","Eddy (Chinese (China mainland))","zh-CN",1,0],["","Eddy (Chinese (Taiwan))","zh-TW",1,0],' +
    '["","Eddy (German (Germany))","de-DE",1,0],["","Eddy (Spanish (Spain))","es-ES",1,0],' +
    '["","Eddy (Spanish (Mexico))","es-MX",1,0],["","Eddy (Finnish (Finland))","fi-FI",1,0],' +
    '["","Eddy (French (Canada))","fr-CA",1,0],["","Eddy (French (France))","fr-FR",1,0],' +
    '["","Eddy (Italian (Italy))","it-IT",1,0],["","Eddy (Japanese (Japan))","ja-JP",1,0],' +
    '["","Eddy (Korean (South Korea))","ko-KR",1,0],["","Eddy (Portuguese (Brazil))","pt-BR",1,0],' +
    '["","Ellen","nl-BE",1,0],' +
    '["","Flo (English (United States))","en-US",1,0],["","Flo (English (United Kingdom))","en-GB",1,0],' +
    '["","Flo (Chinese (China mainland))","zh-CN",1,0],["","Flo (Chinese (Taiwan))","zh-TW",1,0],' +
    '["","Flo (German (Germany))","de-DE",1,0],["","Flo (Spanish (Spain))","es-ES",1,0],' +
    '["","Flo (Spanish (Mexico))","es-MX",1,0],["","Flo (Finnish (Finland))","fi-FI",1,0],' +
    '["","Flo (French (Canada))","fr-CA",1,0],["","Flo (French (France))","fr-FR",1,0],' +
    '["","Flo (Italian (Italy))","it-IT",1,0],["","Flo (Japanese (Japan))","ja-JP",1,0],' +
    '["","Flo (Korean (South Korea))","ko-KR",1,0],["","Flo (Portuguese (Brazil))","pt-BR",1,0],' +
    '["","Fred","en-US",1,0],["","Geeta","te-IN",1,0],["","Good News","en-US",1,0],' +
    '["","Grandma (English (United States))","en-US",1,0],["","Grandma (English (United Kingdom))","en-GB",1,0],' +
    '["","Grandma (Chinese (China mainland))","zh-CN",1,0],["","Grandma (Chinese (Taiwan))","zh-TW",1,0],' +
    '["","Grandma (German (Germany))","de-DE",1,0],["","Grandma (Spanish (Spain))","es-ES",1,0],' +
    '["","Grandma (Spanish (Mexico))","es-MX",1,0],["","Grandma (Finnish (Finland))","fi-FI",1,0],' +
    '["","Grandma (French (Canada))","fr-CA",1,0],["","Grandma (French (France))","fr-FR",1,0],' +
    '["","Grandma (Italian (Italy))","it-IT",1,0],["","Grandma (Japanese (Japan))","ja-JP",1,0],' +
    '["","Grandma (Korean (South Korea))","ko-KR",1,0],["","Grandma (Portuguese (Brazil))","pt-BR",1,0],' +
    '["","Grandpa (English (United States))","en-US",1,0],["","Grandpa (English (United Kingdom))","en-GB",1,0],' +
    '["","Grandpa (Chinese (China mainland))","zh-CN",1,0],["","Grandpa (Chinese (Taiwan))","zh-TW",1,0],' +
    '["","Grandpa (German (Germany))","de-DE",1,0],["","Grandpa (Spanish (Spain))","es-ES",1,0],' +
    '["","Grandpa (Spanish (Mexico))","es-MX",1,0],["","Grandpa (Finnish (Finland))","fi-FI",1,0],' +
    '["","Grandpa (French (Canada))","fr-CA",1,0],["","Grandpa (French (France))","fr-FR",1,0],' +
    '["","Grandpa (Italian (Italy))","it-IT",1,0],["","Grandpa (Japanese (Japan))","ja-JP",1,0],' +
    '["","Grandpa (Korean (South Korea))","ko-KR",1,0],["","Grandpa (Portuguese (Brazil))","pt-BR",1,0],' +
    '["","Ioana","ro-RO",1,0],["","Jacques","fr-FR",1,0],["","Jester","en-US",1,0],' +
    '["","Joana","pt-PT",1,0],["","Junior","en-US",1,0],["","Kanya","th-TH",1,0],' +
    '["","Karen","en-AU",1,0],["","Kathy","en-US",1,0],["","Kyoko","ja-JP",1,0],' +
    '["","Lana","hr-HR",1,0],["","Laura","sk-SK",1,0],["","Lekha","hi-IN",1,0],' +
    '["","Lesya","uk-UA",1,0],["","Linh","vi-VN",1,0],["","Luciana","pt-BR",1,0],' +
    '["","Majed","ar-001",1,0],["","Meijia","zh-TW",1,0],["","Melina","el-GR",1,0],' +
    '["","Milena","ru-RU",1,0],["","Moira","en-IE",1,0],["","Montse","ca-ES",1,0],' +
    '["","Mónica","es-ES",1,0],["","Nora","nb-NO",1,0],["","Organ","en-US",1,0],' +
    '["","Paulina","es-MX",1,0],["","Piya","bn-IN",1,0],["","Ralph","en-US",1,0],' +
    '["","Reed (English (United States))","en-US",1,0],["","Reed (English (United Kingdom))","en-GB",1,0],' +
    '["","Reed (Chinese (China mainland))","zh-CN",1,0],["","Reed (Chinese (Taiwan))","zh-TW",1,0],' +
    '["","Reed (German (Germany))","de-DE",1,0],["","Reed (Spanish (Spain))","es-ES",1,0],' +
    '["","Reed (Spanish (Mexico))","es-MX",1,0],["","Reed (Finnish (Finland))","fi-FI",1,0],' +
    '["","Reed (French (Canada))","fr-CA",1,0],' +
    '["","Reed (Italian (Italy))","it-IT",1,0],["","Reed (Japanese (Japan))","ja-JP",1,0],' +
    '["","Reed (Korean (South Korea))","ko-KR",1,0],["","Reed (Portuguese (Brazil))","pt-BR",1,0],' +
    '["","Rishi","en-IN",1,0],' +
    '["","Rocko (English (United States))","en-US",1,0],["","Rocko (English (United Kingdom))","en-GB",1,0],' +
    '["","Rocko (Chinese (China mainland))","zh-CN",1,0],["","Rocko (Chinese (Taiwan))","zh-TW",1,0],' +
    '["","Rocko (German (Germany))","de-DE",1,0],["","Rocko (Spanish (Spain))","es-ES",1,0],' +
    '["","Rocko (Spanish (Mexico))","es-MX",1,0],["","Rocko (Finnish (Finland))","fi-FI",1,0],' +
    '["","Rocko (French (Canada))","fr-CA",1,0],["","Rocko (French (France))","fr-FR",1,0],' +
    '["","Rocko (Italian (Italy))","it-IT",1,0],["","Rocko (Japanese (Japan))","ja-JP",1,0],' +
    '["","Rocko (Korean (South Korea))","ko-KR",1,0],["","Rocko (Portuguese (Brazil))","pt-BR",1,0],' +
    '["","Sandy (English (United States))","en-US",1,0],["","Sandy (English (United Kingdom))","en-GB",1,0],' +
    '["","Sandy (Chinese (China mainland))","zh-CN",1,0],["","Sandy (Chinese (Taiwan))","zh-TW",1,0],' +
    '["","Sandy (German (Germany))","de-DE",1,0],["","Sandy (Spanish (Spain))","es-ES",1,0],' +
    '["","Sandy (Spanish (Mexico))","es-MX",1,0],["","Sandy (Finnish (Finland))","fi-FI",1,0],' +
    '["","Sandy (French (Canada))","fr-CA",1,0],["","Sandy (French (France))","fr-FR",1,0],' +
    '["","Sandy (Italian (Italy))","it-IT",1,0],["","Sandy (Japanese (Japan))","ja-JP",1,0],' +
    '["","Sandy (Korean (South Korea))","ko-KR",1,0],["","Sandy (Portuguese (Brazil))","pt-BR",1,0],' +
    '["","Sara","da-DK",1,0],["","Satu","fi-FI",1,0],' +
    '["","Shelley (English (United States))","en-US",1,0],["","Shelley (English (United Kingdom))","en-GB",1,0],' +
    '["","Shelley (Chinese (China mainland))","zh-CN",1,0],["","Shelley (Chinese (Taiwan))","zh-TW",1,0],' +
    '["","Shelley (German (Germany))","de-DE",1,0],["","Shelley (Spanish (Spain))","es-ES",1,0],' +
    '["","Shelley (Spanish (Mexico))","es-MX",1,0],["","Shelley (Finnish (Finland))","fi-FI",1,0],' +
    '["","Shelley (French (Canada))","fr-CA",1,0],["","Shelley (French (France))","fr-FR",1,0],' +
    '["","Shelley (Italian (Italy))","it-IT",1,0],["","Shelley (Japanese (Japan))","ja-JP",1,0],' +
    '["","Shelley (Korean (South Korea))","ko-KR",1,0],["","Shelley (Portuguese (Brazil))","pt-BR",1,0],' +
    '["","Sinji","yue-HK",1,0],["","Soumya","kn-IN",1,0],["","Superstar","en-US",1,0],' +
    '["","Tessa","en-ZA",1,0],["","Thomas","fr-FR",1,0],["","Tina","sl-SI",1,0],' +
    '["","Tingting","zh-CN",1,0],["","Trinoids","en-US",1,0],["","Tünde","hu-HU",1,0],' +
    '["","Vani","ta-IN",1,0],["","Whisper","en-US",1,0],["","Wobble","en-US",1,0],' +
    '["","Xander","nl-NL",1,0],["","Yelda","tr-TR",1,0],["","Yuna","ko-KR",1,0],' +
    '["","Zarvox","en-US",1,0],["","Zosia","pl-PL",1,0],["","Zuzana","cs-CZ",1,0],' +
    '["","Google Deutsch","de-DE",0,0],["","Google US English","en-US",0,0],' +
    '["","Google UK English Female","en-GB",0,0],["","Google UK English Male","en-GB",0,0],' +
    '["","Google español","es-ES",0,0],["","Google español de Estados Unidos","es-US",0,0],' +
    '["","Google français","fr-FR",0,0],["","Google हिन्दी","hi-IN",0,0],' +
    '["","Google Bahasa Indonesia","id-ID",0,0],["","Google italiano","it-IT",0,0],' +
    '["","Google 日本語","ja-JP",0,0],["","Google 한국의","ko-KR",0,0],' +
    '["","Google Nederlands","nl-NL",0,0],["","Google polski","pl-PL",0,0],' +
    '["","Google português do Brasil","pt-BR",0,0],["","Google русский","ru-RU",0,0],' +
    '["","Google\\u00a0普通话（中国大陆）","zh-CN",0,0],' +
    '["","Google\\u00a0粤語（香港）","zh-HK",0,0],' +
    '["","Google 國語（臺灣）","zh-TW",0,0]]';

  const DESKTOP_VIDEO_CODEC_RE = /\b(vp09|vp9|av01|hvc1|avc1)\b/;
  const DESKTOP_VP8_CODEC_RE = /\bvp8\b/;
  const DESKTOP_AUDIO_CODEC_RE = /\b(opus|mp4a)\b/;

  function makeNativeFn(name, length, fn) {
    const bound = fn.bind();
    try {
      Object.defineProperty(bound, 'name', { value: name, configurable: true });
      Object.defineProperty(bound, 'length', { value: length, configurable: true });
    } catch (_) {}
    return bound;
  }

  function stripLeaks(w) {
    for (let i = 0; i < IOS_LEAKS.length; i++) {
      const key = IOS_LEAKS[i];
      try {
        if (key in w) {
          delete w[key];
        }
      } catch (_) {}
    }
  }

  function buildMacKeyboardLayoutMap(w) {
    const backing = new w.Map(MAC_EN_US_LAYOUT);
    const proto = w.KeyboardLayoutMap?.prototype || w.Map.prototype;
    const layoutMap = Object.create(proto);
    const entriesFn = makeNativeFn('entries', 0, () => backing.entries());
    Object.defineProperties(layoutMap, {
      size: {
        get: makeNativeFn('get size', 0, () => backing.size),
        enumerable: true,
        configurable: true,
      },
      get: {
        value: makeNativeFn('get', 1, (k) => backing.get(k)),
        writable: true,
        enumerable: false,
        configurable: true,
      },
      has: {
        value: makeNativeFn('has', 1, (k) => backing.has(k)),
        writable: true,
        enumerable: false,
        configurable: true,
      },
      entries: {
        value: entriesFn,
        writable: true,
        enumerable: false,
        configurable: true,
      },
      keys: {
        value: makeNativeFn('keys', 0, () => backing.keys()),
        writable: true,
        enumerable: false,
        configurable: true,
      },
      values: {
        value: makeNativeFn('values', 0, () => backing.values()),
        writable: true,
        enumerable: false,
        configurable: true,
      },
      forEach: {
        value: makeNativeFn('forEach', 1, (cb, thisArg) => {
          backing.forEach((v, k) => cb.call(thisArg, v, k, layoutMap));
        }),
        writable: true,
        enumerable: false,
        configurable: true,
      },
      [w.Symbol.iterator]: {
        value: entriesFn,
        writable: true,
        enumerable: false,
        configurable: true,
      },
    });
    return layoutMap;
  }

  function patchWindow(w) {
    if (!w) return;
    try {
      if (patched.has(w)) return;
      if (w.navigator?.platform !== 'MacIntel') return;
      patched.add(w);
    } catch (_) {
      return;
    }

    // 1. Strip iOS/mobile global leaks immediately and on early lifecycle ticks.
    stripLeaks(w);
    if (w === window) {
      if (typeof w.queueMicrotask === 'function') {
        w.queueMicrotask(() => stripLeaks(w));
      } else {
        w.Promise.resolve().then(() => stripLeaks(w));
      }
      try {
        w.document?.addEventListener('readystatechange', () => stripLeaks(w), { passive: true });
      } catch (_) {}
    }

    // 2. Desktop window.chrome surface (populate only missing members).
    try {
      if (!w.chrome || typeof w.chrome !== 'object') {
        Object.defineProperty(w, 'chrome', {
          value: new w.Object(),
          writable: true,
          enumerable: true,
          configurable: true,
        });
      }
      if (w.chrome && typeof w.chrome === 'object') {
        if (typeof w.chrome.loadTimes !== 'function') {
          Object.defineProperty(w.chrome, 'loadTimes', {
            value: makeNativeFn('loadTimes', 0, () => {
              const nav = w.performance?.getEntriesByType?.('navigation')?.[0];
              const originSec = (w.performance?.timeOrigin || w.Date.now()) / 1000;
              const paint = w.performance?.getEntriesByType?.('paint')?.[0];
              const nextHop = nav?.nextHopProtocol || 'h2';
              return {
                requestTime: originSec,
                startLoadTime: originSec,
                commitLoadTime: originSec + ((nav?.responseStart || 0) / 1000),
                finishDocumentLoadTime: originSec + ((nav?.domContentLoadedEventEnd || 0) / 1000),
                finishLoadTime: originSec + ((nav?.loadEventEnd || 0) / 1000),
                firstPaintTime: paint ? (originSec + (paint.startTime / 1000)) : 0,
                firstPaintAfterLoadTime: 0,
                navigationType: nav?.type === 'reload'
                  ? 'Reload'
                  : (nav?.type === 'back_forward' ? 'BackForward' : 'Other'),
                wasFetchedViaSpdy: nextHop === 'h2' || nextHop === 'h3' || nextHop.startsWith('spdy'),
                wasNpnNegotiated: nextHop === 'h2' || nextHop === 'h3' || nextHop === 'http/1.1',
                npnNegotiatedProtocol: nextHop,
                wasAlternateProtocolAvailable: false,
                connectionInfo: nextHop,
              };
            }),
            writable: true,
            enumerable: true,
            configurable: true,
          });
        }
        if (typeof w.chrome.csi !== 'function') {
          Object.defineProperty(w.chrome, 'csi', {
            value: makeNativeFn('csi', 0, () => {
              const nav = w.performance?.getEntriesByType?.('navigation')?.[0];
              const startE = Math.round(w.performance?.timeOrigin || w.Date.now());
              const onloadT = nav && nav.loadEventEnd > 0
                ? Math.round(startE + nav.loadEventEnd)
                : startE;
              const pageT = Number((w.performance?.now?.() || 0).toFixed(3));
              return {
                startE,
                onloadT,
                pageT,
                tran: 15,
              };
            }),
            writable: true,
            enumerable: true,
            configurable: true,
          });
        }
        if (typeof w.chrome.app === 'undefined') {
          Object.defineProperty(w.chrome, 'app', {
            value: {
              isInstalled: false,
              InstallState: {
                DISABLED: 'disabled',
                INSTALLED: 'installed',
                NOT_INSTALLED: 'not_installed',
              },
              RunningState: {
                CANNOT_RUN: 'cannot_run',
                READY_TO_RUN: 'ready_to_run',
                RUNNING: 'running',
              },
              getDetails: makeNativeFn('getDetails', 0, () => null),
              getIsInstalled: makeNativeFn('getIsInstalled', 0, () => false),
              runningState: makeNativeFn('runningState', 0, () => 'cannot_run'),
            },
            writable: true,
            enumerable: true,
            configurable: true,
          });
        }
      }
    } catch (_) {}

    // 3. Notification & Permissions parity (map unprompted 'denied' -> 'default'/'prompt').
    try {
      if (w.Notification) {
        const permDesc = Object.getOwnPropertyDescriptor(w.Notification, 'permission');
        if (permDesc && typeof permDesc.get === 'function' && permDesc.configurable !== false) {
          const origPermGet = permDesc.get;
          Object.defineProperty(w.Notification, 'permission', {
            get: makeNativeFn('get permission', 0, () => {
              const val = origPermGet.call(w.Notification);
              return val === 'denied' ? 'default' : val;
            }),
            enumerable: permDesc.enumerable,
            configurable: true,
          });
        }
      }
    } catch (_) {}

    try {
      if (w.Permissions && w.Permissions.prototype &&
          typeof w.Permissions.prototype.query === 'function') {
        const origQuery = w.Permissions.prototype.query;
        const wrappedQuery = makeNativeFn('query', 1, (...args) => {
          const p = origQuery.apply(w.navigator.permissions, args);
          const desc = args[0];
          if (!desc || desc.name !== 'notifications') return p;
          return p.then((status) => {
            if (!status || status.state !== 'denied') return status;
            try {
              Object.defineProperty(status, 'state', {
                get: makeNativeFn('get state', 0, () => 'prompt'),
                enumerable: true,
                configurable: true,
              });
              return status;
            } catch (_) {
              const proto = Object.getPrototypeOf(status) || w.PermissionStatus?.prototype || w.Object.prototype;
              const fallback = Object.create(proto);
              Object.defineProperties(fallback, {
                name: {
                  get: makeNativeFn('get name', 0, () => status.name || 'notifications'),
                  enumerable: true,
                  configurable: true,
                },
                state: {
                  get: makeNativeFn('get state', 0, () => 'prompt'),
                  enumerable: true,
                  configurable: true,
                },
                onchange: {
                  get: makeNativeFn('get onchange', 0, () => status.onchange),
                  set: makeNativeFn('set onchange', 1, (v) => { status.onchange = v; }),
                  enumerable: true,
                  configurable: true,
                },
              });
              return fallback;
            }
          });
        });
        Object.defineProperty(w.Permissions.prototype, 'query', {
          value: wrappedQuery,
          writable: true,
          enumerable: true,
          configurable: true,
        });
      }
    } catch (_) {}

    // 4. NetworkInformation.rtt (map 0 -> 50 ms when native reports zero).
    try {
      const netProto = w.NetworkInformation?.prototype
        || (w.navigator?.connection ? Object.getPrototypeOf(w.navigator.connection) : null);
      if (netProto) {
        const rttDesc = Object.getOwnPropertyDescriptor(netProto, 'rtt');
        if (rttDesc && typeof rttDesc.get === 'function' && rttDesc.configurable !== false) {
          const origRtt = rttDesc.get;
          Object.defineProperty(netProto, 'rtt', {
            get: makeNativeFn('get rtt', 0, () => {
              const val = origRtt.call(w.navigator.connection);
              return val === 0 ? 50 : val;
            }),
            enumerable: rttDesc.enumerable,
            configurable: true,
          });
        }
      }
    } catch (_) {}

    // 5. macOS top menu bar Screen.prototype.availTop & availLeft.
    try {
      if (w.Screen && w.Screen.prototype) {
        const screenProto = w.Screen.prototype;
        const availTopDesc = Object.getOwnPropertyDescriptor(screenProto, 'availTop');
        if (!availTopDesc || availTopDesc.configurable !== false) {
          const origAvailTop = availTopDesc?.get;
          Object.defineProperty(screenProto, 'availTop', {
            get: makeNativeFn('get availTop', 0, () => {
              const nativeAvailTop = origAvailTop ? origAvailTop.call(w.screen) : 0;
              const h = w.screen.height;
              const ah = w.screen.availHeight;
              if (nativeAvailTop === 0 && h > ah) {
                return h - ah;
              }
              return nativeAvailTop;
            }),
            enumerable: availTopDesc ? availTopDesc.enumerable : true,
            configurable: true,
          });
        }

        const availLeftDesc = Object.getOwnPropertyDescriptor(screenProto, 'availLeft');
        if (!availLeftDesc || availLeftDesc.configurable !== false) {
          const origAvailLeft = availLeftDesc?.get;
          Object.defineProperty(screenProto, 'availLeft', {
            get: makeNativeFn('get availLeft', 0, () => {
              const val = origAvailLeft ? origAvailLeft.call(w.screen) : 0;
              return typeof val === 'number' ? val : 0;
            }),
            enumerable: availLeftDesc ? availLeftDesc.enumerable : true,
            configurable: true,
          });
        }
      }
    } catch (_) {}

    // 6. window.devicePixelRatio (normalize 3x iPhone Retina to 2x macOS Retina only when 3).
    try {
      if (w.devicePixelRatio === 3) {
        const dprDesc = Object.getOwnPropertyDescriptor(w, 'devicePixelRatio');
        if (!dprDesc || dprDesc.configurable !== false) {
          Object.defineProperty(w, 'devicePixelRatio', {
            get: makeNativeFn('get devicePixelRatio', 0, () => 2),
            enumerable: dprDesc ? dprDesc.enumerable : true,
            configurable: true,
          });
        }
      }
    } catch (_) {}

    // 7. PresentationRequest.prototype.reconnect (normalize iOS no-MediaRouter error; preserve `this`).
    try {
      if (w.PresentationRequest && w.PresentationRequest.prototype &&
          typeof w.PresentationRequest.prototype.reconnect === 'function') {
        const origReconnect = w.PresentationRequest.prototype.reconnect;
        const wrappedReconnect = function reconnect(id) {
          try {
            const result = origReconnect.apply(this, arguments);
            if (result && typeof result.then === 'function') {
              return result.then(undefined, (err) => {
                const msg = err && typeof err.message === 'string' ? err.message : String(err || '');
                if (msg.includes('No matching route')) {
                  throw new w.DOMException('Route not found', 'NotFoundError');
                }
                throw err;
              });
            }
            return result;
          } catch (err) {
            const msg = err && typeof err.message === 'string' ? err.message : String(err || '');
            if (msg.includes('No matching route')) {
              throw new w.DOMException('Route not found', 'NotFoundError');
            }
            throw err;
          }
        };
        Object.defineProperty(w.PresentationRequest.prototype, 'reconnect', {
          value: wrappedReconnect,
          writable: true,
          enumerable: true,
          configurable: true,
        });
      }
    } catch (_) {}

    // 8. Keyboard.prototype.getLayoutMap (pass through non-empty map; fallback to 48-key macOS en-US).
    try {
      if (w.Keyboard && w.Keyboard.prototype &&
          typeof w.Keyboard.prototype.getLayoutMap === 'function') {
        const origGetLayoutMap = w.Keyboard.prototype.getLayoutMap;
        const wrappedGetLayoutMap = makeNativeFn('getLayoutMap', 0, () => {
          return origGetLayoutMap.call(w.navigator.keyboard).then((realMap) => {
            if (realMap && realMap.size > 0) return realMap;
            return buildMacKeyboardLayoutMap(w);
          });
        });
        Object.defineProperty(w.Keyboard.prototype, 'getLayoutMap', {
          value: wrappedGetLayoutMap,
          writable: true,
          enumerable: true,
          configurable: true,
        });
      }
    } catch (_) {}

    // 9. SpeechSynthesis.prototype.getVoices (pass through non-empty list; lazy macOS + Google TTS).
    try {
      if (w.SpeechSynthesis && w.SpeechSynthesis.prototype &&
          typeof w.SpeechSynthesis.prototype.getVoices === 'function') {
        const origGetVoices = w.SpeechSynthesis.prototype.getVoices;
        let cachedVoices = null;
        const getFallbackVoices = () => {
          if (cachedVoices) return cachedVoices;
          const rows = JSON.parse(VOICES_JSON);
          const voiceProto = w.SpeechSynthesisVoice?.prototype || w.Object.prototype;
          const list = new w.Array(rows.length);
          for (let i = 0; i < rows.length; i++) {
            const row = rows[i];
            const uri = row[0] || row[1];
            const name = row[1];
            const lang = row[2];
            const localService = row[3] === 1;
            const isDefault = row[4] === 1;
            const voice = Object.create(voiceProto);
            Object.defineProperties(voice, {
              voiceURI: {
                get: makeNativeFn('get voiceURI', 0, () => uri),
                enumerable: true,
                configurable: true,
              },
              name: {
                get: makeNativeFn('get name', 0, () => name),
                enumerable: true,
                configurable: true,
              },
              lang: {
                get: makeNativeFn('get lang', 0, () => lang),
                enumerable: true,
                configurable: true,
              },
              localService: {
                get: makeNativeFn('get localService', 0, () => localService),
                enumerable: true,
                configurable: true,
              },
              default: {
                get: makeNativeFn('get default', 0, () => isDefault),
                enumerable: true,
                configurable: true,
              },
            });
            list[i] = voice;
          }
          cachedVoices = list;
          return cachedVoices;
        };

        const wrappedGetVoices = makeNativeFn('getVoices', 0, () => {
          const real = origGetVoices.call(w.speechSynthesis);
          if (real && real.length > 0) return real;
          return w.Array.prototype.slice.call(getFallbackVoices());
        });
        Object.defineProperty(w.SpeechSynthesis.prototype, 'getVoices', {
          value: wrappedGetVoices,
          writable: true,
          enumerable: true,
          configurable: true,
        });
      }
    } catch (_) {}

    // 10. MediaCapabilities.prototype.decodingInfo (file probes without keySystemConfiguration only).
    try {
      if (w.MediaCapabilities && w.MediaCapabilities.prototype &&
          typeof w.MediaCapabilities.prototype.decodingInfo === 'function') {
        const origDecodingInfo = w.MediaCapabilities.prototype.decodingInfo;
        const wrappedDecodingInfo = makeNativeFn('decodingInfo', 1, (...args) => {
          const p = origDecodingInfo.apply(w.navigator.mediaCapabilities, args);
          const cfg = args[0];
          if (!cfg || cfg.type !== 'file' || cfg.keySystemConfiguration) return p;
          const hasVideo = Boolean(cfg.video && typeof cfg.video.contentType === 'string');
          const hasAudio = Boolean(cfg.audio && typeof cfg.audio.contentType === 'string');
          if (!hasVideo && !hasAudio) return p;

          const videoCT = hasVideo ? cfg.video.contentType.toLowerCase() : '';
          const audioCT = hasAudio ? cfg.audio.contentType.toLowerCase() : '';
          const isVP8 = hasVideo && DESKTOP_VP8_CODEC_RE.test(videoCT);
          const isDesktopVideo = hasVideo && (isVP8 || DESKTOP_VIDEO_CODEC_RE.test(videoCT));
          const isDesktopAudio = hasAudio && DESKTOP_AUDIO_CODEC_RE.test(audioCT);

          if ((hasVideo && !isDesktopVideo) || (hasAudio && !isDesktopAudio)) {
            return p;
          }
          const powerEfficient = !isVP8;
          return p.then((res) => Object.assign(new w.Object(), res || {}, {
            supported: true,
            smooth: true,
            powerEfficient,
          }));
        });
        Object.defineProperty(w.MediaCapabilities.prototype, 'decodingInfo', {
          value: wrappedDecodingInfo,
          writable: true,
          enumerable: true,
          configurable: true,
        });
      }
    } catch (_) {}

    // 11. PublicKeyCredential.getClientCapabilities (merge macOS Touch ID / passkey / PRF / payment).
    try {
      if (w.PublicKeyCredential &&
          typeof w.PublicKeyCredential.getClientCapabilities === 'function') {
        const origGetCaps = w.PublicKeyCredential.getClientCapabilities;
        const wrappedGetCaps = makeNativeFn('getClientCapabilities', 0, () => {
          return origGetCaps.call(w.PublicKeyCredential).then((caps) =>
            Object.assign(new w.Object(), caps || {}, {
              userVerifyingPlatformAuthenticator: true,
              passkeyPlatformAuthenticator: true,
              'extension:payment': true,
              'extension:prf': true,
            })
          );
        });
        Object.defineProperty(w.PublicKeyCredential, 'getClientCapabilities', {
          value: wrappedGetCaps,
          writable: true,
          enumerable: true,
          configurable: true,
        });
      }
    } catch (_) {}

    // 12. Chrome 138+ desktop built-in AI static surface (only when undefined).
    try {
      if (typeof w.LanguageDetector === 'undefined') {
        const LanguageDetector = makeNativeFn('LanguageDetector', 0, function () {
          throw new w.TypeError('Illegal constructor');
        });
        Object.defineProperty(LanguageDetector, 'availability', {
          value: makeNativeFn('availability', 0, () => w.Promise.resolve('available')),
          writable: true,
          enumerable: true,
          configurable: true,
        });
        Object.defineProperty(w, 'LanguageDetector', {
          value: LanguageDetector,
          writable: true,
          enumerable: false,
          configurable: true,
        });
      }
      if (typeof w.Summarizer === 'undefined') {
        const Summarizer = makeNativeFn('Summarizer', 0, function () {
          throw new w.TypeError('Illegal constructor');
        });
        Object.defineProperty(Summarizer, 'availability', {
          value: makeNativeFn('availability', 0, () => w.Promise.resolve('unavailable')),
          writable: true,
          enumerable: true,
          configurable: true,
        });
        Object.defineProperty(w, 'Summarizer', {
          value: Summarizer,
          writable: true,
          enumerable: false,
          configurable: true,
        });
      }
    } catch (_) {}

    // 13. Iframe propagation (synchronously patch same-origin & about:blank iframes before first access).
    try {
      if (w.HTMLIFrameElement && w.HTMLIFrameElement.prototype) {
        const iframeProto = w.HTMLIFrameElement.prototype;
        const cwDesc = Object.getOwnPropertyDescriptor(iframeProto, 'contentWindow');
        if (cwDesc && typeof cwDesc.get === 'function' && cwDesc.configurable !== false) {
          const origCW = cwDesc.get;
          const cwGet = function contentWindow() {
            const cw = origCW.call(this);
            if (cw) {
              try { patchWindow(cw); } catch (_) {}
            }
            return cw;
          };
          try {
            Object.defineProperty(cwGet, 'name', { value: 'get contentWindow', configurable: true });
          } catch (_) {}
          Object.defineProperty(iframeProto, 'contentWindow', {
            get: cwGet,
            enumerable: cwDesc.enumerable,
            configurable: true,
          });
        }

        const cdDesc = Object.getOwnPropertyDescriptor(iframeProto, 'contentDocument');
        if (cdDesc && typeof cdDesc.get === 'function' && cdDesc.configurable !== false) {
          const origCD = cdDesc.get;
          const origCW = cwDesc?.get;
          const cdGet = function contentDocument() {
            const doc = origCD.call(this);
            if (doc) {
              try {
                const cw = doc.defaultView || (origCW ? origCW.call(this) : null);
                if (cw) patchWindow(cw);
              } catch (_) {}
            }
            return doc;
          };
          try {
            Object.defineProperty(cdGet, 'name', { value: 'get contentDocument', configurable: true });
          } catch (_) {}
          Object.defineProperty(iframeProto, 'contentDocument', {
            get: cdGet,
            enumerable: cdDesc.enumerable,
            configurable: true,
          });
        }
      }
    } catch (_) {}
  }

  patchWindow(window);
})();
"""#

    private static var contentSignature: String {
        let combined = Data((manifestJSON + "\n---\n" + parityScript).utf8)
        let digest = SHA256.hash(data: combined)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Materializes `manifest.json` and `desktop_parity.js` into
    /// `<trustedUnpackedRoot>/curium_desktop_parity/`. Skips disk writes when an
    /// existing directory already matches the current content signature and bytes.
    @discardableResult
    static func materialize(into trustedUnpackedRoot: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: trustedUnpackedRoot, withIntermediateDirectories: true)

        let targetDir = trustedUnpackedRoot.appending(path: directoryName, directoryHint: .isDirectory)
        let manifestURL = targetDir.appending(path: "manifest.json", directoryHint: .notDirectory)
        let scriptURL = targetDir.appending(path: "desktop_parity.js", directoryHint: .notDirectory)
        let stampURL = targetDir.appending(path: versionStampFileName, directoryHint: .notDirectory)

        let manifestData = Data(manifestJSON.utf8)
        let scriptData = Data(parityScript.utf8)
        let signature = contentSignature
        if fm.fileExists(atPath: targetDir.path),
           let existingStamp = try? String(contentsOf: stampURL, encoding: .utf8),
           existingStamp == signature,
           let existingManifest = try? Data(contentsOf: manifestURL),
           existingManifest == manifestData,
           let existingScript = try? Data(contentsOf: scriptURL),
           existingScript == scriptData {
            return targetDir
        }

        let stagingDir = trustedUnpackedRoot.appending(
            path: ".\(directoryName).staging-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? fm.removeItem(at: stagingDir) }

        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try manifestData.write(
            to: stagingDir.appending(path: "manifest.json", directoryHint: .notDirectory),
            options: .atomic
        )
        try scriptData.write(
            to: stagingDir.appending(path: "desktop_parity.js", directoryHint: .notDirectory),
            options: .atomic
        )
        try Data(signature.utf8).write(
            to: stagingDir.appending(path: versionStampFileName, directoryHint: .notDirectory),
            options: .atomic
        )

        if fm.fileExists(atPath: targetDir.path) {
            _ = try fm.replaceItemAt(targetDir, withItemAt: stagingDir)
        } else {
            try fm.moveItem(at: stagingDir, to: targetDir)
        }
        return targetDir
    }

    // MARK: - Idempotent Runtime Bootstrap

    private struct TrustedInstallOutcome: Sendable {
        let id: String?
        let isEnabled: Bool
        let error: NSError?
    }

    @MainActor
    private final class WeakManagerBox {
        weak var value: AnyObject?
        init(_ value: AnyObject) { self.value = value }
    }

    @MainActor private static var completedManagers: [(box: WeakManagerBox, enabled: Bool)] = []
    @MainActor private static var inFlightInstalls: [(box: WeakManagerBox, task: Task<Void, Never>)] = []

    @MainActor
    static func ensureInstalled(
        using manager: any CrIOSExtensionManagingV1,
        enabled: Bool = true
    ) async {
        let managerObj = manager as AnyObject
        completedManagers.removeAll { $0.box.value == nil }
        inFlightInstalls.removeAll { $0.box.value == nil }

        if let existing = inFlightInstalls.first(where: { $0.box.value === managerObj }) {
            await existing.task.value
            completedManagers.removeAll { $0.box.value == nil }
        }

        if let idx = completedManagers.firstIndex(where: { $0.box.value === managerObj }) {
            if completedManagers[idx].enabled != enabled {
                if let entry = (try? manager.extensions())?.first(where: { ($0["id"] as? String) == extensionID }),
                   (entry["enabled"] as? Bool) != enabled {
                    try? manager.setExtensionWithID(extensionID, enabled: enabled)
                }
                completedManagers[idx].enabled = enabled
            }
            return
        }

        let task = Task<Void, Never> { @MainActor in
            let done = await installWithRetry(using: manager, enabled: enabled)
            if done {
                completedManagers.removeAll { $0.box.value == nil || $0.box.value === managerObj }
                completedManagers.append((WeakManagerBox(managerObj), enabled))
            }
        }
        inFlightInstalls.append((WeakManagerBox(managerObj), task))
        await task.value
        inFlightInstalls.removeAll { $0.box.value == nil || $0.box.value === managerObj }
    }

    @MainActor
    private static func installWithRetry(
        using manager: any CrIOSExtensionManagingV1,
        enabled: Bool
    ) async -> Bool {
        let totalAttempts = retryBackoffs.count + 1
        for attempt in 0..<totalAttempts {
            var dirError: NSError?
            let rootPath = CuriumTrustedUnpackedExtensionsDirectory(manager, &dirError)
            guard let rootPath, !rootPath.isEmpty else {
                let err = dirError ?? NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
                if err.domain == NSCocoaErrorDomain && err.code == NSFeatureUnsupportedError {
                    return true
                }
                if isTransientStartupError(err), attempt < retryBackoffs.count {
                    try? await Task.sleep(for: retryBackoffs[attempt])
                    continue
                }
                log.error("CuriumDesktopParity trusted root failed: \(err.localizedDescription, privacy: .public)")
                return false
            }

            let extDir: URL
            do {
                extDir = try materialize(into: URL(fileURLWithPath: rootPath, isDirectory: true))
            } catch {
                log.error("CuriumDesktopParity materialize failed: \(error.localizedDescription, privacy: .public)")
                return false
            }

            if let existing = (try? manager.extensions())?.first(where: { ($0["id"] as? String) == extensionID }),
               (existing["version"] as? String) == manifestVersion {
                if (existing["enabled"] as? Bool) != enabled {
                    try? manager.setExtensionWithID(extensionID, enabled: enabled)
                }
                return true
            }

            let outcome = await installTrustedDirectory(extDir.path, using: manager)
            if outcome.error == nil {
                let installedID = outcome.id ?? extensionID
                if outcome.isEnabled != enabled {
                    try? manager.setExtensionWithID(installedID, enabled: enabled)
                }
                log.notice("CuriumDesktopParity installed cleanly (id=\(installedID, privacy: .public), enabled=\(enabled))")
                return true
            }

            let nsError = outcome.error ?? NSError(
                domain: "CuriumDesktopParityExtension",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Trusted extension install returned no result."]
            )
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFeatureUnsupportedError {
                return true
            }
            if let existing = (try? manager.extensions())?.first(where: { ($0["id"] as? String) == extensionID }) {
                if (existing["enabled"] as? Bool) != enabled {
                    try? manager.setExtensionWithID(extensionID, enabled: enabled)
                }
                return true
            }
            if isTransientStartupError(nsError), attempt < retryBackoffs.count {
                try? await Task.sleep(for: retryBackoffs[attempt])
                continue
            }
            log.error("CuriumDesktopParity install failed: \(nsError.localizedDescription, privacy: .public)")
            return false
        }
        return false
    }

    @MainActor
    private static func installTrustedDirectory(
        _ path: String,
        using manager: any CrIOSExtensionManagingV1
    ) async -> TrustedInstallOutcome {
        await withCheckedContinuation { continuation in
            CuriumInstallTrustedUnpackedExtension(manager, path) { result, error in
                let id = result?["id"] as? String
                let isEnabled = (result?["enabled"] as? Bool) ?? false
                let nsError = error as NSError?
                continuation.resume(returning: TrustedInstallOutcome(id: id, isEnabled: isEnabled, error: nsError))
            }
        }
    }

    private static func isTransientStartupError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSFeatureUnsupportedError {
            return false
        }
        let desc = error.localizedDescription.lowercased()
        if desc.contains("restoring installed extensions")
            || desc.contains("not ready")
            || desc.contains("not initialized")
            || desc.contains("no valid non-otr")
            || desc.contains("already in progress") {
            return true
        }
        if error.domain == "CrIOSExtensionManagerErrorDomain" {
            return error.code == 3 || error.code == 5
        }
        return false
    }
}
