import CryptoKit
import CuriumEngineContract
import Foundation
import OSLog

/// Built-in Manifest V3 content-script extension loaded into Chromium's
/// `TrustedUnpackedExtensions` directory at startup and hidden from user-facing
/// extension lists.
///
/// Two content scripts cooperate across Blink worlds on every HTTP(S) frame:
/// - `pip_guard.js` (`MAIN`, `document_start`): locks `disablePictureInPicture = false`,
///   blocks unsolicited `exitPictureInPicture()`, and shields active PiP playback from
///   `visibilitychange` / `blur` background-pause handlers without altering normal tabs.
/// - `pip_overlay.js` (`ISOLATED`, `document_idle`): mounts a closed ShadowDOM floating
///   PiP pill button anchored to each eligible playing/recently-paused `<video>`.
enum CuriumVideoPiPExtension {
    static let directoryName = "curium_video_pip"
    static let versionStampFileName = ".curium_version"

    /// Static RSA-2048 SubjectPublicKeyInfo (DER, base64-encoded).
    /// The corresponding private key was discarded at generation time; only this
    /// public key is embedded so Chromium derives a deterministic extension ID.
    static let publicKeyBase64 =
        "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA5MZG3muKPYcfuM2A0J4o"
        + "+uXcccpNAgiP8xuQysY0nWU1wBkBCyyQj+tlVARWtySOGotNV0N4O0rb4uyektiV"
        + "4NCfdNCcSV30OQGx3YWSB2x8zk4xRBXxLUylLS2prIGvbL+Y+EyGporwTEpZG9t+"
        + "mVMoNKmi9nL+6xTdHxq3/kdtv6W2UdBJy4qdRbrsEO3SsYymqdyhEhTp8fWjECVj"
        + "BJ7J6NSqYxtuCTUQ7KiwJhr97exmJj8TScie8jmUCMg8R51OHirlnTqyOff2+p6R"
        + "L9qTBfqIOT2Ta0tF3htZ2L1zazJPMOxRC+IPtp+DYuHWwR7sFvTQ9qiSp+8glRak"
        + "7QIDAQAB"

    static let extensionID = "kogjboefmhkckeddcmekebknpjlhkhid"
    static let hiddenExtensionIDs: Set<String> = [extensionID]

    private static let log = Logger(subsystem: "com.appautomaton.curium", category: "pip")
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
        let stripped = publicKeyBase64
            .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
            .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard !stripped.isEmpty,
              let derData = Data(base64Encoded: stripped),
              !derData.isEmpty else {
            return nil
        }
        let digest = SHA256.hash(data: derData)
        let alphabet = Array("abcdefghijklmnop".utf8)
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        for byte in digest.prefix(16) {
            bytes.append(alphabet[Int((byte >> 4) & 0x0F)])
            bytes.append(alphabet[Int(byte & 0x0F)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static var manifestJSON: String {
        let manifest: [String: Any] = [
            "manifest_version": 3,
            "name": "Curium Video PiP",
            "version": "1.0.0",
            "key": publicKeyBase64,
            "content_scripts": [
                [
                    "matches": ["http://*/*", "https://*/*"],
                    "js": ["pip_guard.js"],
                    "run_at": "document_start",
                    "world": "MAIN",
                    "all_frames": true,
                    "match_about_blank": true,
                ],
                [
                    "matches": ["http://*/*", "https://*/*"],
                    "js": ["pip_overlay.js"],
                    "run_at": "document_idle",
                    "world": "ISOLATED",
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
            preconditionFailure("CuriumVideoPiPExtension manifest serialization failed")
        }
        return text + "\n"
    }

    static let guardScript: String = #"""
(() => {
  'use strict';

  const GUARD_KEY = Symbol.for('com.appautomaton.curium.pipGuard');
  if (window[GUARD_KEY]) return;
  try {
    Object.defineProperty(window, GUARD_KEY, {
      value: true,
      configurable: false,
      enumerable: false,
      writable: false,
    });
  } catch (_) {
    return;
  }

  const ElementProto = typeof Element !== 'undefined' ? Element.prototype : null;
  const HTMLVideoProto = typeof HTMLVideoElement !== 'undefined' ? HTMLVideoElement.prototype : null;
  const HTMLMediaProto = typeof HTMLMediaElement !== 'undefined' ? HTMLMediaElement.prototype : null;
  const DocProto = typeof Document !== 'undefined' ? Document.prototype : null;
  const NavProto = typeof Navigator !== 'undefined' ? Navigator.prototype : null;

  if (!ElementProto || !HTMLVideoProto || !HTMLMediaProto || !DocProto) return;

  const origSetAttribute = ElementProto.setAttribute;
  const origSetAttributeNS = ElementProto.setAttributeNS;
  const origToggleAttribute = ElementProto.toggleAttribute;
  const origRemoveAttribute = ElementProto.removeAttribute;
  const origRequestPiP = HTMLVideoProto.requestPictureInPicture;
  const origExitPiP = DocProto.exitPictureInPicture;
  const origMediaPause = HTMLMediaProto.pause;

  const origHiddenDesc = Object.getOwnPropertyDescriptor(DocProto, 'hidden');
  const origVisStateDesc = Object.getOwnPropertyDescriptor(DocProto, 'visibilityState');
  const origWebkitHiddenDesc = Object.getOwnPropertyDescriptor(DocProto, 'webkitHidden');
  const origWebkitVisStateDesc = Object.getOwnPropertyDescriptor(DocProto, 'webkitVisibilityState');
  const origPiPElementDesc = Object.getOwnPropertyDescriptor(DocProto, 'pictureInPictureElement');
  const origUserActivationDesc = NavProto ? Object.getOwnPropertyDescriptor(NavProto, 'userActivation') : null;

  let lastPiPIntentAt = -1e9;
  let lastPiPEnterAt = -1e9;
  let lastBlurAt = -1e9;

  const isVideo = (el) => {
    if (!el || el.nodeType !== 1) return false;
    if (el instanceof HTMLVideoElement) return true;
    return el.localName === 'video' && el.namespaceURI === 'http://www.w3.org/1999/xhtml';
  };

  const getPiPElement = (doc) => {
    const target = doc || document;
    try {
      if (origPiPElementDesc && origPiPElementDesc.get) {
        return origPiPElementDesc.get.call(target);
      }
      return target.pictureInPictureElement || null;
    } catch (_) {
      return null;
    }
  };

  const isHiddenRaw = (doc) => {
    const target = doc || document;
    try {
      if (origHiddenDesc && origHiddenDesc.get) {
        return !!origHiddenDesc.get.call(target);
      }
      return false;
    } catch (_) {
      return false;
    }
  };

  const hasActiveUserActivation = () => {
    try {
      const ua = origUserActivationDesc && origUserActivationDesc.get
        ? origUserActivationDesc.get.call(navigator)
        : navigator.userActivation;
      return !!(ua && ua.isActive);
    } catch (_) {
      return false;
    }
  };

  const isPiPActive = (doc) => {
    if (getPiPElement(doc) != null) return true;
    return performance.now() - lastPiPIntentAt < 1200;
  };

  const stripDisablePiPAttr = (el) => {
    try {
      if (origRemoveAttribute && isVideo(el)) {
        origRemoveAttribute.call(el, 'disablepictureinpicture');
      }
    } catch (_) {}
  };

  const stripAllDisablePiP = (root) => {
    try {
      if (!root || typeof root.querySelectorAll !== 'function') return;
      const videos = root.querySelectorAll('video[disablepictureinpicture]');
      for (let i = 0; i < videos.length; i++) {
        stripDisablePiPAttr(videos[i]);
      }
    } catch (_) {}
  };

  // Permanently lock disablePictureInPicture = false across all <video> elements.
  try {
    Object.defineProperty(HTMLVideoProto, 'disablePictureInPicture', {
      configurable: false,
      enumerable: true,
      get() { return false; },
      set() { stripDisablePiPAttr(this); },
    });
  } catch (_) {}

  if (origSetAttribute) {
    ElementProto.setAttribute = function(name, value) {
      if (typeof name === 'string' && name.toLowerCase() === 'disablepictureinpicture' && isVideo(this)) {
        stripDisablePiPAttr(this);
        return;
      }
      return origSetAttribute.apply(this, arguments);
    };
  }

  if (origSetAttributeNS) {
    ElementProto.setAttributeNS = function(ns, name, value) {
      if (typeof name === 'string') {
        const colon = name.indexOf(':');
        const local = colon >= 0 ? name.slice(colon + 1) : name;
        if (local.toLowerCase() === 'disablepictureinpicture' && isVideo(this)) {
          stripDisablePiPAttr(this);
          return;
        }
      }
      return origSetAttributeNS.apply(this, arguments);
    };
  }

  if (origToggleAttribute) {
    ElementProto.toggleAttribute = function(name, force) {
      if (typeof name === 'string' && name.toLowerCase() === 'disablepictureinpicture' && isVideo(this)) {
        stripDisablePiPAttr(this);
        return false;
      }
      return origToggleAttribute.apply(this, arguments);
    };
  }

  if (origRequestPiP) {
    HTMLVideoProto.requestPictureInPicture = function() {
      stripDisablePiPAttr(this);
      lastPiPIntentAt = performance.now();
      return origRequestPiP.apply(this, arguments);
    };
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => stripAllDisablePiP(document), { capture: true, once: true });
  } else {
    stripAllDisablePiP(document);
  }

  // Cross-world PiP intent signal from pip_overlay.js and native PiP enter/leave lifecycle.
  document.addEventListener('__curium_pip_intent', () => {
    lastPiPIntentAt = performance.now();
  }, true);

  document.addEventListener('enterpictureinpicture', () => {
    lastPiPEnterAt = performance.now();
  }, true);

  document.addEventListener('leavepictureinpicture', () => {
    lastPiPIntentAt = -1e9;
  }, true);

  // Block hostile script-driven exitPictureInPicture() right after entering or without user gesture.
  if (origExitPiP) {
    DocProto.exitPictureInPicture = function() {
      if (getPiPElement(this) != null) {
        const now = performance.now();
        if (now - lastPiPEnterAt < 3500 || now - lastPiPIntentAt < 3500 || !hasActiveUserActivation()) {
          return Promise.resolve();
        }
      }
      return origExitPiP.apply(this, arguments);
    };
  }

  // Shield active PiP videos from visibilitychange / blur background-pause traps
  // while leaving normal non-PiP background tabs completely untouched.
  const overrideVisibilityGetter = (prop, origDesc, pipValue) => {
    if (!origDesc || typeof origDesc.get !== 'function') return;
    try {
      Object.defineProperty(DocProto, prop, {
        configurable: origDesc.configurable,
        enumerable: origDesc.enumerable,
        get() {
          if (isPiPActive(this)) return pipValue;
          return origDesc.get.call(this);
        },
      });
    } catch (_) {}
  };

  overrideVisibilityGetter('hidden', origHiddenDesc, false);
  overrideVisibilityGetter('visibilityState', origVisStateDesc, 'visible');
  overrideVisibilityGetter('webkitHidden', origWebkitHiddenDesc, false);
  overrideVisibilityGetter('webkitVisibilityState', origWebkitVisStateDesc, 'visible');

  const swallowVisibilityIfPiP = (e) => {
    if (isPiPActive(document)) {
      e.stopImmediatePropagation();
    }
  };
  window.addEventListener('visibilitychange', swallowVisibilityIfPiP, true);
  document.addEventListener('visibilitychange', swallowVisibilityIfPiP, true);
  window.addEventListener('webkitvisibilitychange', swallowVisibilityIfPiP, true);
  document.addEventListener('webkitvisibilitychange', swallowVisibilityIfPiP, true);

  window.addEventListener('blur', () => {
    if (getPiPElement(document) != null) {
      lastBlurAt = performance.now();
    }
  }, true);

  if (origMediaPause) {
    HTMLMediaProto.pause = function() {
      const doc = (this && this.ownerDocument) || document;
      const activeEl = getPiPElement(doc);
      if (activeEl && this === activeEl) {
        const now = performance.now();
        const inEnterTrapWindow = (now - lastPiPEnterAt < 400) || (now - lastPiPIntentAt < 400);
        const inBackgroundTrap = !hasActiveUserActivation() &&
          (isHiddenRaw(doc) || (now - lastBlurAt < 1000));
        if (inEnterTrapWindow || inBackgroundTrap) {
          return;
        }
      }
      return origMediaPause.apply(this, arguments);
    };
  }
})();
"""#

    static let overlayScript: String = #"""
(() => {
  'use strict';

  const OVERLAY_GUARD = Symbol.for('com.appautomaton.curium.pipOverlay');
  if (window[OVERLAY_GUARD]) return;
  try {
    Object.defineProperty(window, OVERLAY_GUARD, {
      value: true,
      configurable: false,
      enumerable: false,
      writable: false,
    });
  } catch (_) {
    return;
  }

  const PAUSE_GRACE_MS = 4000;
  const IDLE_DIM_MS = 3500;
  const BTN_SIZE = 44;
  const MIN_VIDEO_W = 140;
  const MIN_VIDEO_H = 90;
  const MIN_VIS_W = 80;
  const MIN_VIS_H = 60;

  const trackedVideos = new Set();
  const videoState = new WeakMap();
  const observedRoots = new WeakSet();
  const shadowObservers = new WeakMap();

  let host = null;
  let layer = null;
  let resizeObserver = null;
  let viewportListenersAttached = false;
  let rafId = 0;
  let scanTimerId = 0;
  let housekeepingTimerId = 0;
  const pendingScanRoots = new Set();
  let needsFullPrune = false;

  const clamp = (val, min, max) => (val < min ? min : (val > max ? max : val));

  const isVideo = (node) => {
    if (!node || node.nodeType !== 1) return false;
    if (node instanceof HTMLVideoElement) return true;
    return node.localName === 'video' && node.namespaceURI === 'http://www.w3.org/1999/xhtml';
  };

  const getPiPElement = () => {
    try {
      return document.pictureInPictureElement || null;
    } catch (_) {
      return null;
    }
  };

  const getMountTarget = () => {
    const fs = document.fullscreenElement || document.webkitFullscreenElement;
    if (fs && fs instanceof Element && !isVideo(fs)) {
      return fs;
    }
    return document.documentElement || document.body;
  };

  const ensureOverlayMounted = () => {
    const target = getMountTarget();
    if (!target) return null;
    if (!host) {
      host = document.createElement('div');
      host.setAttribute('data-curium-pip-overlay', '1');
      host.style.cssText =
        'all: initial !important; position: fixed !important; inset: 0 !important; ' +
        'pointer-events: none !important; z-index: 2147483647 !important;';

      const shadow = host.attachShadow({ mode: 'closed' });
      const style = document.createElement('style');
      style.textContent = `
        :host {
          all: initial !important;
          position: fixed !important;
          inset: 0 !important;
          pointer-events: none !important;
          z-index: 2147483647 !important;
        }
        .curium-pip-layer {
          position: fixed;
          inset: 0;
          pointer-events: none;
          z-index: 2147483647;
          contain: layout style;
        }
        .curium-pip-layer[hidden] {
          display: none;
        }
        .curium-pip-btn {
          position: fixed;
          left: 0;
          top: 0;
          width: 44px;
          height: 44px;
          padding: 0;
          margin: 0;
          border: 0;
          background: transparent;
          pointer-events: auto;
          display: flex;
          align-items: center;
          justify-content: center;
          touch-action: manipulation;
          -webkit-tap-highlight-color: transparent;
          cursor: pointer;
          opacity: 0.92;
          transition: opacity 220ms ease;
          user-select: none;
          -webkit-user-select: none;
          will-change: transform, opacity;
        }
        .curium-pip-btn.dimmed {
          opacity: 0.42;
        }
        .curium-pip-pill {
          width: 34px;
          height: 34px;
          border-radius: 17px;
          display: flex;
          align-items: center;
          justify-content: center;
          background: rgba(18, 18, 22, 0.64);
          backdrop-filter: blur(14px) saturate(160%);
          -webkit-backdrop-filter: blur(14px) saturate(160%);
          border: 0.5px solid rgba(255, 255, 255, 0.24);
          box-shadow: 0 2px 10px rgba(0, 0, 0, 0.28);
          transition: transform 120ms cubic-bezier(0.2, 0.8, 0.2, 1);
          pointer-events: none;
        }
        .curium-pip-btn:active .curium-pip-pill {
          transform: scale(0.90);
        }
      `;

      layer = document.createElement('div');
      layer.className = 'curium-pip-layer';
      shadow.appendChild(style);
      shadow.appendChild(layer);
    }

    if (!host.isConnected || host.parentElement !== target) {
      target.appendChild(host);
    }
    return layer;
  };

  const createButtonForVideo = (video, state) => {
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'curium-pip-btn';
    btn.setAttribute('aria-label', 'Picture in Picture');

    const pill = document.createElement('span');
    pill.className = 'curium-pip-pill';

    const svgNS = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(svgNS, 'svg');
    svg.setAttribute('width', '17');
    svg.setAttribute('height', '17');
    svg.setAttribute('viewBox', '0 0 20 20');
    svg.setAttribute('aria-hidden', 'true');

    const frame = document.createElementNS(svgNS, 'rect');
    frame.setAttribute('x', '2');
    frame.setAttribute('y', '3.5');
    frame.setAttribute('width', '16');
    frame.setAttribute('height', '13');
    frame.setAttribute('rx', '2.4');
    frame.setAttribute('fill', 'none');
    frame.setAttribute('stroke', '#fff');
    frame.setAttribute('stroke-width', '1.6');

    const inset = document.createElementNS(svgNS, 'rect');
    inset.setAttribute('x', '10.2');
    inset.setAttribute('y', '9.8');
    inset.setAttribute('width', '5.8');
    inset.setAttribute('height', '4.4');
    inset.setAttribute('rx', '1.1');
    inset.setAttribute('fill', '#fff');

    const arrow = document.createElementNS(svgNS, 'path');
    arrow.setAttribute('d', 'M5.4 6.4 L8.6 9.6 M6.3 9.6 H8.6 V7.3');
    arrow.setAttribute('fill', 'none');
    arrow.setAttribute('stroke', '#fff');
    arrow.setAttribute('stroke-width', '1.55');
    arrow.setAttribute('stroke-linecap', 'round');
    arrow.setAttribute('stroke-linejoin', 'round');

    svg.appendChild(frame);
    svg.appendChild(inset);
    svg.appendChild(arrow);
    pill.appendChild(svg);
    btn.appendChild(pill);

    const stopOnly = (e) => {
      e.stopPropagation();
    };
    const wakeAndStop = (e) => {
      e.stopPropagation();
      state.lastBrightAt = performance.now();
      btn.classList.remove('dimmed');
      scheduleLayout();
    };

    btn.addEventListener('touchstart', wakeAndStop, { passive: true });
    btn.addEventListener('pointerdown', wakeAndStop, { passive: true });
    btn.addEventListener('mousedown', wakeAndStop);
    btn.addEventListener('touchend', stopOnly, { passive: true });
    btn.addEventListener('pointerup', stopOnly, { passive: true });
    btn.addEventListener('mouseup', stopOnly);

    btn.addEventListener('click', (e) => {
      e.preventDefault();
      e.stopPropagation();
      state.lastBrightAt = performance.now();
      btn.classList.remove('dimmed');

      try {
        video.removeAttribute('disablepictureinpicture');
      } catch (_) {}
      try {
        video.disablePictureInPicture = false;
      } catch (_) {}

      document.dispatchEvent(new CustomEvent('__curium_pip_intent'));

      try {
        if (typeof video.requestPictureInPicture === 'function') {
          const pending = video.requestPictureInPicture();
          if (pending && typeof pending.catch === 'function') {
            pending.catch(() => {});
          }
        }
      } catch (_) {}
    });

    return btn;
  };

  const getOrInitState = (video) => {
    let state = videoState.get(video);
    if (!state) {
      state = {
        hasPlayed: false,
        pausedAt: 0,
        lastBrightAt: performance.now(),
        btn: null,
      };
      videoState.set(video, state);
    }
    return state;
  };

  const registerVideo = (video) => {
    if (!isVideo(video) || !video.isConnected) return;
    const isNew = !trackedVideos.has(video);
    trackedVideos.add(video);
    const state = getOrInitState(video);
    if (!video.paused && !video.ended && video.readyState >= 2) {
      if (!state.hasPlayed) {
        state.lastBrightAt = performance.now();
      }
      state.hasPlayed = true;
      state.pausedAt = 0;
    }
    if (isNew && resizeObserver) {
      try { resizeObserver.observe(video); } catch (_) {}
    }
  };

  const removeButtonForState = (state) => {
    if (state && state.btn) {
      if (state.btn.parentNode) {
        state.btn.parentNode.removeChild(state.btn);
      }
      state.btn = null;
    }
  };

  const onViewportChange = () => {
    const now = performance.now();
    for (const v of trackedVideos) {
      const state = videoState.get(v);
      if (state && state.btn) {
        state.lastBrightAt = now;
      }
    }
    scheduleLayout();
  };

  const syncViewportObservers = () => {
    const hasVideos = trackedVideos.size > 0;
    if (hasVideos && !viewportListenersAttached) {
      viewportListenersAttached = true;
      document.addEventListener('scroll', onViewportChange, { capture: true, passive: true });
      window.addEventListener('scroll', onViewportChange, { passive: true });
      window.addEventListener('resize', onViewportChange, { passive: true });
      if (window.visualViewport) {
        window.visualViewport.addEventListener('resize', onViewportChange, { passive: true });
        window.visualViewport.addEventListener('scroll', onViewportChange, { passive: true });
      }
      if (!resizeObserver && typeof ResizeObserver === 'function') {
        resizeObserver = new ResizeObserver(() => scheduleLayout());
      }
      if (resizeObserver) {
        for (const v of trackedVideos) {
          try { resizeObserver.observe(v); } catch (_) {}
        }
      }
    } else if (!hasVideos && viewportListenersAttached) {
      viewportListenersAttached = false;
      document.removeEventListener('scroll', onViewportChange, true);
      window.removeEventListener('scroll', onViewportChange);
      window.removeEventListener('resize', onViewportChange);
      if (window.visualViewport) {
        window.visualViewport.removeEventListener('resize', onViewportChange);
        window.visualViewport.removeEventListener('scroll', onViewportChange);
      }
      if (resizeObserver) {
        resizeObserver.disconnect();
      }
    }
  };

  const scheduleHousekeeping = (delayMs) => {
    if (housekeepingTimerId) {
      clearTimeout(housekeepingTimerId);
      housekeepingTimerId = 0;
    }
    if (!Number.isFinite(delayMs) || delayMs < 0) return;
    housekeepingTimerId = setTimeout(() => {
      housekeepingTimerId = 0;
      scheduleLayout();
    }, Math.max(25, Math.ceil(delayMs)));
  };

  const scheduleLayout = () => {
    if (rafId) return;
    rafId = requestAnimationFrame(runLayout);
  };

  const runLayout = () => {
    rafId = 0;
    const now = performance.now();
    const pipEl = getPiPElement();
    const vw = document.documentElement ? (document.documentElement.clientWidth || window.innerWidth) : window.innerWidth;
    const vh = document.documentElement ? (document.documentElement.clientHeight || window.innerHeight) : window.innerHeight;
    const vv = window.visualViewport;
    const vpLeft = vv && Number.isFinite(vv.offsetLeft) ? Math.max(0, vv.offsetLeft) : 0;
    const vpTop = vv && Number.isFinite(vv.offsetTop) ? Math.max(0, vv.offsetTop) : 0;
    const vpRight = vv && Number.isFinite(vv.width) && vv.width > 0 ? Math.min(vw, vpLeft + vv.width) : vw;
    const vpBottom = vv && Number.isFinite(vv.height) && vv.height > 0 ? Math.min(vh, vpTop + vv.height) : vh;

    const placedRects = [];
    let visibleCount = 0;
    let nextWakeMs = Infinity;

    for (const video of Array.from(trackedVideos)) {
      const state = videoState.get(video);
      if (!video.isConnected) {
        removeButtonForState(state);
        trackedVideos.delete(video);
        if (resizeObserver) {
          try { resizeObserver.unobserve(video); } catch (_) {}
        }
        continue;
      }

      if (!state) continue;

      if (!video.paused && !video.ended && video.readyState >= 2) {
        state.hasPlayed = true;
        state.pausedAt = 0;
      }

      const activelyPlaying = !video.paused && !video.ended;
      let recentlyPaused = false;
      if (!activelyPlaying && !video.ended && state.hasPlayed && state.pausedAt > 0) {
        const pausedElapsed = now - state.pausedAt;
        if (pausedElapsed <= PAUSE_GRACE_MS) {
          recentlyPaused = true;
          nextWakeMs = Math.min(nextWakeMs, PAUSE_GRACE_MS - pausedElapsed + 30);
        }
      }

      let eligible =
        video.readyState >= 2 &&
        video.videoWidth > 0 &&
        video.videoHeight > 0 &&
        (activelyPlaying || recentlyPaused) &&
        pipEl !== video;

      let visLeft = 0;
      let visTop = 0;
      let visRight = 0;
      let visBottom = 0;

      if (eligible) {
        const rect = video.getBoundingClientRect();
        if (rect.width < MIN_VIDEO_W || rect.height < MIN_VIDEO_H) {
          eligible = false;
        } else {
          visLeft = Math.max(vpLeft, rect.left);
          visTop = Math.max(vpTop, rect.top);
          visRight = Math.min(vpRight, rect.right);
          visBottom = Math.min(vpBottom, rect.bottom);
          if (visRight - visLeft < MIN_VIS_W || visBottom - visTop < MIN_VIS_H) {
            eligible = false;
          }
        }
      }

      if (eligible) {
        if (typeof video.checkVisibility === 'function' &&
            !video.checkVisibility({ opacityProperty: true, visibilityProperty: true })) {
          eligible = false;
        } else {
          const cs = getComputedStyle(video);
          if (cs.display === 'none' || cs.visibility === 'hidden' || parseFloat(cs.opacity) <= 0.05) {
            eligible = false;
          }
        }
      }

      if (!eligible) {
        removeButtonForState(state);
        continue;
      }

      const container = ensureOverlayMounted();
      if (!container) {
        removeButtonForState(state);
        continue;
      }

      if (!state.btn) {
        state.btn = createButtonForVideo(video, state);
        container.appendChild(state.btn);
      } else if (state.btn.parentNode !== container) {
        container.appendChild(state.btn);
      }

      const minLeft = Math.max(vpLeft + 4, visLeft + 4);
      const maxLeft = Math.max(minLeft, vpRight - BTN_SIZE - 4);
      const minTop = vpTop + 4;
      const maxTop = Math.max(minTop, vpBottom - BTN_SIZE - 4);
      let left = clamp(visRight - BTN_SIZE - 6, minLeft, maxLeft);
      let top = clamp(visTop + 6, minTop, maxTop);

      for (let attempt = 0; attempt < 4; attempt++) {
        const overlaps = placedRects.some((r) =>
          left < r.right + 4 && left + BTN_SIZE > r.left - 4 &&
          top < r.bottom + 4 && top + BTN_SIZE > r.top - 4
        );
        if (!overlaps) break;
        if (top + BTN_SIZE + 4 <= Math.min(visBottom, vpBottom - 4)) {
          top += BTN_SIZE + 4;
        } else if (left - BTN_SIZE - 4 >= minLeft) {
          left -= BTN_SIZE + 4;
        } else {
          break;
        }
      }

      placedRects.push({ left, top, right: left + BTN_SIZE, bottom: top + BTN_SIZE });
      state.btn.style.transform = `translate3d(${Math.round(left)}px, ${Math.round(top)}px, 0)`;

      const brightElapsed = now - state.lastBrightAt;
      if (brightElapsed >= IDLE_DIM_MS) {
        state.btn.classList.add('dimmed');
      } else {
        state.btn.classList.remove('dimmed');
        nextWakeMs = Math.min(nextWakeMs, IDLE_DIM_MS - brightElapsed + 30);
      }
      visibleCount += 1;
    }

    if (layer) {
      layer.hidden = visibleCount === 0;
    }

    syncViewportObservers();
    scheduleHousekeeping(visibleCount > 0 ? nextWakeMs : Infinity);
  };

  const MEDIA_EVENTS = [
    'playing', 'play', 'loadeddata', 'canplay',
    'pause', 'ended', 'emptied',
    'enterpictureinpicture', 'leavepictureinpicture', 'resize',
  ];

  const onMediaEvent = (e) => {
    const target = e.target;
    if (!isVideo(target)) return;

    if (e.type === 'emptied') {
      const state = videoState.get(target);
      if (state) {
        state.hasPlayed = false;
        state.pausedAt = 0;
        removeButtonForState(state);
      }
      if (!target.isConnected) {
        trackedVideos.delete(target);
      }
      scheduleLayout();
      return;
    }

    registerVideo(target);
    const state = getOrInitState(target);
    const now = performance.now();

    if (e.type === 'playing' || (e.type === 'play' && !target.paused && !target.ended && target.readyState >= 2)) {
      state.hasPlayed = true;
      state.pausedAt = 0;
      state.lastBrightAt = now;
    } else if (e.type === 'pause') {
      if (state.hasPlayed && !target.ended) {
        state.pausedAt = now;
      }
    } else if (e.type === 'ended') {
      state.hasPlayed = false;
      state.pausedAt = 0;
    } else if (e.type === 'leavepictureinpicture') {
      if (!target.paused && !target.ended) {
        state.lastBrightAt = now;
      }
    }

    syncViewportObservers();
    scheduleLayout();
  };

  const attachRootListeners = (root) => {
    if (!root || observedRoots.has(root)) return;
    observedRoots.add(root);
    for (const evt of MEDIA_EVENTS) {
      root.addEventListener(evt, onMediaEvent, { capture: true, passive: true });
    }
    if (root instanceof ShadowRoot && !shadowObservers.has(root)) {
      const mo = new MutationObserver(handleMutations);
      mo.observe(root, { childList: true, subtree: true });
      shadowObservers.set(root, mo);
    }
  };

  const scanRoot = (root) => {
    if (!root) return;
    if (root === host) return;

    if (root instanceof ShadowRoot) {
      attachRootListeners(root);
    }

    if (isVideo(root)) {
      registerVideo(root);
    }

    if (root instanceof Element && root.shadowRoot) {
      attachRootListeners(root.shadowRoot);
      scanRoot(root.shadowRoot);
    }

    if (typeof root.querySelectorAll === 'function') {
      const videos = root.querySelectorAll('video');
      for (let i = 0; i < videos.length; i++) {
        registerVideo(videos[i]);
      }
    }

    try {
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
      let node = walker.currentNode;
      while (node) {
        if (node !== host && node.shadowRoot) {
          attachRootListeners(node.shadowRoot);
          scanRoot(node.shadowRoot);
        }
        node = walker.nextNode();
      }
    } catch (_) {}
  };

  const flushPendingScans = () => {
    scanTimerId = 0;
    const roots = Array.from(pendingScanRoots);
    pendingScanRoots.clear();
    let changed = needsFullPrune;
    needsFullPrune = false;

    for (const root of roots) {
      if (root.isConnected || root === document || root instanceof ShadowRoot) {
        const before = trackedVideos.size;
        scanRoot(root);
        if (trackedVideos.size !== before) changed = true;
      }
    }

    for (const v of Array.from(trackedVideos)) {
      if (!v.isConnected) {
        removeButtonForState(videoState.get(v));
        trackedVideos.delete(v);
        if (resizeObserver) {
          try { resizeObserver.unobserve(v); } catch (_) {}
        }
        changed = true;
      }
    }

    if (changed || trackedVideos.size > 0) {
      syncViewportObservers();
      scheduleLayout();
    }
  };

  const scheduleScan = () => {
    if (scanTimerId) return;
    scanTimerId = setTimeout(flushPendingScans, 120);
  };

  function handleMutations(records) {
    for (let i = 0; i < records.length; i++) {
      const record = records[i];
      if (record.removedNodes.length > 0 && trackedVideos.size > 0) {
        needsFullPrune = true;
      }
      const added = record.addedNodes;
      for (let j = 0; j < added.length; j++) {
        const node = added[j];
        if (node && node.nodeType === 1 && node !== host) {
          pendingScanRoots.add(node);
        }
      }
    }
    if (needsFullPrune || pendingScanRoots.size > 0) {
      scheduleScan();
    }
  }

  const start = () => {
    attachRootListeners(document);
    document.addEventListener('fullscreenchange', scheduleLayout, true);
    document.addEventListener('webkitfullscreenchange', scheduleLayout, true);

    const rootEl = document.documentElement || document.body;
    if (rootEl) {
      scanRoot(rootEl);
      const observer = new MutationObserver(handleMutations);
      observer.observe(rootEl, { childList: true, subtree: true });
    }
    if (trackedVideos.size > 0) {
      syncViewportObservers();
      scheduleLayout();
    }
  };

  if (document.documentElement) {
    start();
  } else {
    document.addEventListener('DOMContentLoaded', start, { once: true });
  }
})();
"""#

    private static var contentSignature: String {
        let combined = Data((manifestJSON + "\n---\n" + guardScript + "\n---\n" + overlayScript).utf8)
        let digest = SHA256.hash(data: combined)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Materializes `manifest.json`, `pip_guard.js`, and `pip_overlay.js` into
    /// `<trustedUnpackedRoot>/curium_video_pip/`. Skips disk writes when an existing
    /// directory already matches the current content signature.
    @discardableResult
    static func materialize(into trustedUnpackedRoot: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: trustedUnpackedRoot, withIntermediateDirectories: true)

        let targetDir = trustedUnpackedRoot.appending(path: directoryName, directoryHint: .isDirectory)
        let manifestURL = targetDir.appending(path: "manifest.json", directoryHint: .notDirectory)
        let guardURL = targetDir.appending(path: "pip_guard.js", directoryHint: .notDirectory)
        let overlayURL = targetDir.appending(path: "pip_overlay.js", directoryHint: .notDirectory)
        let stampURL = targetDir.appending(path: versionStampFileName, directoryHint: .notDirectory)

        let signature = contentSignature
        if fm.fileExists(atPath: targetDir.path),
           fm.fileExists(atPath: manifestURL.path),
           fm.fileExists(atPath: guardURL.path),
           fm.fileExists(atPath: overlayURL.path),
           let existingStamp = try? String(contentsOf: stampURL, encoding: .utf8),
           existingStamp == signature {
            return targetDir
        }

        let stagingDir = trustedUnpackedRoot.appending(
            path: ".\(directoryName).staging-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? fm.removeItem(at: stagingDir) }

        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try Data(manifestJSON.utf8).write(
            to: stagingDir.appending(path: "manifest.json", directoryHint: .notDirectory),
            options: .atomic
        )
        try Data(guardScript.utf8).write(
            to: stagingDir.appending(path: "pip_guard.js", directoryHint: .notDirectory),
            options: .atomic
        )
        try Data(overlayScript.utf8).write(
            to: stagingDir.appending(path: "pip_overlay.js", directoryHint: .notDirectory),
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

    @MainActor private static let completedManagers = NSHashTable<AnyObject>.weakObjects()
    @MainActor private static var inFlightInstalls: [(box: WeakManagerBox, task: Task<Void, Never>)] = []

    @MainActor
    static func ensureInstalled(using manager: any CrIOSExtensionManagingV1) async {
        let managerObj = manager as AnyObject
        inFlightInstalls.removeAll { $0.box.value == nil }

        if completedManagers.contains(managerObj) {
            return
        }
        if let existing = inFlightInstalls.first(where: { $0.box.value === managerObj }) {
            await existing.task.value
            return
        }

        let task = Task<Void, Never> { @MainActor in
            let done = await installWithRetry(using: manager)
            if done {
                completedManagers.add(managerObj)
            }
        }
        inFlightInstalls.append((WeakManagerBox(managerObj), task))
        await task.value
        inFlightInstalls.removeAll { $0.box.value === nil || $0.box.value === managerObj }
    }

    @MainActor
    private static func installWithRetry(using manager: any CrIOSExtensionManagingV1) async -> Bool {
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
                log.error("CuriumVideoPiP trusted root failed: \(err.localizedDescription, privacy: .public)")
                return false
            }

            if let existing = (try? manager.extensions())?.first(where: { ($0["id"] as? String) == extensionID }) {
                if (existing["enabled"] as? Bool) != true {
                    try? manager.setExtensionWithID(extensionID, enabled: true)
                }
                return true
            }

            let extDir: URL
            do {
                extDir = try materialize(into: URL(fileURLWithPath: rootPath, isDirectory: true))
            } catch {
                log.error("CuriumVideoPiP materialize failed: \(error.localizedDescription, privacy: .public)")
                return false
            }

            let outcome = await installTrustedDirectory(extDir.path, using: manager)
            if outcome.error == nil {
                let installedID = outcome.id ?? extensionID
                if !outcome.isEnabled {
                    try? manager.setExtensionWithID(installedID, enabled: true)
                }
                log.notice("CuriumVideoPiP installed cleanly (id=\(installedID, privacy: .public))")
                return true
            }

            let nsError = outcome.error ?? NSError(
                domain: "CuriumVideoPiPExtension",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Trusted extension install returned no result."]
            )
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFeatureUnsupportedError {
                return true
            }
            if let existing = (try? manager.extensions())?.first(where: { ($0["id"] as? String) == extensionID }) {
                if (existing["enabled"] as? Bool) != true {
                    try? manager.setExtensionWithID(extensionID, enabled: true)
                }
                return true
            }
            if isTransientStartupError(nsError), attempt < retryBackoffs.count {
                try? await Task.sleep(for: retryBackoffs[attempt])
                continue
            }
            log.error("CuriumVideoPiP install failed: \(nsError.localizedDescription, privacy: .public)")
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
