import { ALL_FORMATS, CanvasSink, Input, UrlSource } from "mediabunny";
import { createMixer, createCpuMixer } from "./mixer.js";

const video = document.querySelector("video");
const output = document.querySelector("#output");
const status = document.querySelector("#status");
const strength = document.querySelector("#strength");
let session;
let mediaURL;
let openSequence = 0;

function showOriginal() {
  video.classList.remove("filtered");
  output.replaceChildren();
}

function stopMixer(message = "Original") {
  const previous = session;
  session = null;
  if (previous) {
    cancelAnimationFrame(previous.tick);
    clearInterval(previous.watchdog);
    previous.input.dispose();
    previous.mixer?.close();
  }
  showOriginal();
  status.textContent = message;
}

async function startMixer() {
  stopMixer();
  if (!mediaURL || strength.value === "off") return;
  status.textContent = "Preparing smoothing";
  const input = new Input({
    source: new UrlSource(mediaURL),
    formats: ALL_FORMATS,
  });
  const current = { input, tick: 0, watchdog: 0, mixer: null };
  session = current;
  function fallback() {
    if (session === current)
      stopMixer("Smoothing unavailable. Original playback continues.");
  }
  try {
    const track = await input.getPrimaryVideoTrack();
    if (session !== current) return;
    if (!track || (await track.isLive()) || !(await track.canDecode()))
      return fallback();
    const color = await track.getColorSpace();
    if (["pq", "hlg", "smpte2084", "arib-std-b67"].includes(color?.transfer))
      return fallback();
    const sourceWidth = await track.getDisplayWidth();
    const sourceHeight = await track.getDisplayHeight();
    if (session !== current) return;
    const ratio = Math.min(1, 960 / sourceWidth, 540 / sourceHeight);
    const width = Math.max(1, Math.round(sourceWidth * ratio));
    const height = Math.max(1, Math.round(sourceHeight * ratio));
    current.mixer = createMixer(width, height);
    const sink = new CanvasSink(track, {
      width,
      height,
      fit: "contain",
      poolSize: 5,
    });
    const iterator = sink.canvases(video.currentTime);
    let first = (await iterator.next()).value;
    let second = (await iterator.next()).value;
    if (session !== current) return;

    // Keep the original surface visible if the independent decoder stalls.
    current.watchdog = setInterval(() => {
      if (
        !video.paused &&
        second &&
        video.currentTime > second.timestamp + 0.25
      )
        showOriginal();
    }, 100);

    async function draw() {
      try {
        if (session !== current) return;
        if (second && video.currentTime - second.timestamp > 1)
          return fallback();
        while (second && second.timestamp <= video.currentTime) {
          first = second;
          second = (await iterator.next()).value;
          if (session !== current) return;
        }
        if (!first || !second) return stopMixer();
        const interval = second.timestamp - first.timestamp;
        if (
          interval <= 0 ||
          interval > 0.25 ||
          video.currentTime < first.timestamp
        ) {
          showOriginal();
        } else {
          const phase = Math.min(
            1,
            (video.currentTime - first.timestamp) / interval
          );
          const weight =
            strength.value === "performance" && (phase < 0.25 || phase > 0.75)
              ? Math.round(phase)
              : phase;
          try {
            current.mixer.draw(first, second, weight);
          } catch (error) {
            if (current.mixer.provider === "CPU") throw error;
            current.mixer.close();
            current.mixer = createCpuMixer(width, height);
            current.mixer.draw(first, second, weight);
          }
          if (output.firstChild !== current.mixer.canvas)
            output.replaceChildren(current.mixer.canvas);
          video.classList.add("filtered");
          status.textContent = current.mixer.provider;
        }
        current.tick = requestAnimationFrame(draw);
      } catch {
        fallback();
      }
    }
    await draw();
  } catch {
    fallback();
  }
}

strength.addEventListener("change", () => {
  if (strength.value === "off" || !session) void startMixer();
});
video.addEventListener("seeking", () => stopMixer());
video.addEventListener("seeked", () => {
  if (strength.value !== "off") void startMixer();
});
video.addEventListener("ended", () => stopMixer());
video.addEventListener("error", () => stopMixer("Playback failed."));
video.addEventListener("encrypted", () => {
  strength.value = "off";
  stopMixer();
});
document.querySelector("#toggle").onclick = () => {
  if (video.paused)
    video.play().catch(() => {
      status.textContent = "Playback failed.";
    });
  else video.pause();
};
document.querySelector("#open").onsubmit = async (event) => {
  event.preventDefault();
  let uri;
  try {
    uri = new URL(document.querySelector("#url").value);
  } catch {
    status.textContent = "Enter a valid media URL.";
    return;
  }
  if (uri.protocol !== "https:" || uri.username || uri.password) {
    status.textContent = "Enter an HTTPS media URL.";
    return;
  }
  const sequence = ++openSequence;
  stopMixer();
  mediaURL = uri.href;
  video.src = mediaURL;
  try {
    await video.play();
    if (sequence === openSequence && strength.value !== "off")
      await startMixer();
  } catch {
    if (sequence === openSequence) status.textContent = "Playback failed.";
  }
};
