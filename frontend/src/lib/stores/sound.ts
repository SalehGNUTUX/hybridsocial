/**
 * Plays short notification + message sounds in response to realtime
 * events. Two dials, both stored in localStorage so the user's
 * preference persists across sessions:
 *
 *   - `sound_message_enabled`       — DM arrival sound (default on)
 *   - `sound_notification_enabled`  — bell sound for non-DM notifs (default on)
 *
 * The audio files live at `/sounds/message.mp3` and
 * `/sounds/notification.mp3` (served from `static/`). Missing files
 * are treated as "silent" — the playback call swallows the 404 so
 * shipping the UI before the sound assets land doesn't throw.
 *
 * Browsers block autoplay until the user has interacted with the
 * page. We attempt a silent priming play() on first user gesture to
 * unlock audio; after that, notification sounds play instantly.
 */

import { browser } from '$app/environment';

const MESSAGE_KEY = 'sound_message_enabled';
const NOTIFICATION_KEY = 'sound_notification_enabled';

const MESSAGE_SOUND_URL = '/sounds/message.mp3';
const NOTIFICATION_SOUND_URL = '/sounds/notification.mp3';

// Cache `Audio` instances so repeated plays don't re-fetch the file.
// Cloning before play lets overlapping events (two DMs within 200ms)
// both make a sound instead of cutting each other off.
let messageAudio: HTMLAudioElement | null = null;
let notificationAudio: HTMLAudioElement | null = null;

// Flipped to `true` by the audio elements' `error` handlers when the
// preload 404s. Used to short-circuit subsequent play attempts so the
// console isn't flooded with the same missing-file error on every
// chat event.
let messageAssetMissing = false;
let notificationAssetMissing = false;

let audioUnlocked = false;

export function initSound(): void {
  if (!browser) return;

  messageAudio = new Audio(MESSAGE_SOUND_URL);
  notificationAudio = new Audio(NOTIFICATION_SOUND_URL);
  messageAudio.preload = 'auto';
  notificationAudio.preload = 'auto';

  messageAudio.addEventListener('error', () => {
    messageAssetMissing = true;
  });
  notificationAudio.addEventListener('error', () => {
    notificationAssetMissing = true;
  });

  // Gesture-gated audio unlock. Any click/keypress primes the audio
  // elements with a silent play so subsequent programmatic plays
  // aren't blocked by the browser's autoplay policy.
  const unlock = () => {
    if (audioUnlocked) return;
    audioUnlocked = true;

    [messageAudio, notificationAudio].forEach((a) => {
      if (!a) return;
      const prev = a.volume;
      a.volume = 0;
      a.play()
        .then(() => {
          a.pause();
          a.currentTime = 0;
          a.volume = prev;
        })
        .catch(() => {
          // Still locked, or missing file — either way we'll retry
          // on the next gesture.
        });
    });

    window.removeEventListener('click', unlock);
    window.removeEventListener('keydown', unlock);
  };

  window.addEventListener('click', unlock, { once: false });
  window.addEventListener('keydown', unlock, { once: false });
}

export function playMessageSound(): void {
  if (!browser) return;
  if (messageAssetMissing) return;
  if (localStorage.getItem(MESSAGE_KEY) === 'false') return;
  play(messageAudio);
}

export function playNotificationSound(): void {
  if (!browser) return;
  if (notificationAssetMissing) return;
  if (localStorage.getItem(NOTIFICATION_KEY) === 'false') return;
  play(notificationAudio);
}

function play(source: HTMLAudioElement | null): void {
  if (!source) return;

  try {
    // Cloning the node lets stacked events each produce a sound —
    // `source.play()` on a currently-playing element is a no-op in
    // most browsers, which would cut off rapid-fire notifications.
    const clone = source.cloneNode(true) as HTMLAudioElement;
    const promise = clone.play();
    if (promise) promise.catch(() => {});
  } catch {
    // Missing file / autoplay blocked / decoder issue — silently skip.
  }
}

export function setMessageSoundEnabled(enabled: boolean): void {
  if (!browser) return;
  localStorage.setItem(MESSAGE_KEY, enabled ? 'true' : 'false');
}

export function setNotificationSoundEnabled(enabled: boolean): void {
  if (!browser) return;
  localStorage.setItem(NOTIFICATION_KEY, enabled ? 'true' : 'false');
}

export function getMessageSoundEnabled(): boolean {
  if (!browser) return true;
  return localStorage.getItem(MESSAGE_KEY) !== 'false';
}

export function getNotificationSoundEnabled(): boolean {
  if (!browser) return true;
  return localStorage.getItem(NOTIFICATION_KEY) !== 'false';
}
