const modes = {
  focus: { label: 'Focus', status: 'Ready to focus', input: 'focus-min' },
  short: { label: 'Short break', status: 'Time for a short break', input: 'short-min' },
  long: { label: 'Long break', status: 'Take a longer reset', input: 'long-min' },
};

const timeEl = document.querySelector('#time');
const statusEl = document.querySelector('#status');
const startBtn = document.querySelector('#start');
const resetBtn = document.querySelector('#reset');
const modeBtns = [...document.querySelectorAll('.mode')];
const inputs = [...document.querySelectorAll('input[type="number"]')];
const meter = document.querySelector('.meter');
const radius = 96;
const circumference = 2 * Math.PI * radius;

let currentMode = 'focus';
let totalSeconds = getModeSeconds(currentMode);
let remainingSeconds = totalSeconds;
let timerId = null;
let running = false;

meter.style.strokeDasharray = `${circumference}`;

function getModeSeconds(mode) {
  const input = document.getElementById(modes[mode].input);
  const minutes = Math.max(1, Number(input.value) || 1);
  return minutes * 60;
}

function formatTime(seconds) {
  const minutes = Math.floor(seconds / 60).toString().padStart(2, '0');
  const secs = Math.floor(seconds % 60).toString().padStart(2, '0');
  return `${minutes}:${secs}`;
}

function render() {
  timeEl.textContent = formatTime(remainingSeconds);
  document.title = `${formatTime(remainingSeconds)} — Pomodoro`;

  const elapsedRatio = totalSeconds ? 1 - remainingSeconds / totalSeconds : 0;
  meter.style.strokeDashoffset = String(circumference * elapsedRatio);

  if (!running) {
    statusEl.textContent = modes[currentMode].status;
  }
}

function start() {
  if (running) {
    pause();
    return;
  }

  running = true;
  startBtn.textContent = 'Pause';
  statusEl.textContent = currentMode === 'focus' ? 'Focus in progress' : 'Break in progress';

  const endAt = Date.now() + remainingSeconds * 1000;
  timerId = window.setInterval(() => {
    remainingSeconds = Math.max(0, Math.round((endAt - Date.now()) / 1000));
    render();

    if (remainingSeconds <= 0) {
      complete();
    }
  }, 250);
}

function pause() {
  running = false;
  startBtn.textContent = 'Start';
  statusEl.textContent = 'Paused';
  window.clearInterval(timerId);
}

function reset() {
  running = false;
  window.clearInterval(timerId);
  startBtn.textContent = 'Start';
  totalSeconds = getModeSeconds(currentMode);
  remainingSeconds = totalSeconds;
  render();
}

function complete() {
  running = false;
  window.clearInterval(timerId);
  startBtn.textContent = 'Start';
  statusEl.textContent = `${modes[currentMode].label} complete`;
  chime();
}

function setMode(mode) {
  currentMode = mode;
  modeBtns.forEach((button) => {
    const active = button.dataset.mode === mode;
    button.classList.toggle('active', active);
    button.setAttribute('aria-selected', String(active));
  });
  reset();
}

function chime() {
  const AudioContext = window.AudioContext || window.webkitAudioContext;
  if (!AudioContext) return;

  const audio = new AudioContext();
  const oscillator = audio.createOscillator();
  const gain = audio.createGain();

  oscillator.type = 'sine';
  oscillator.frequency.setValueAtTime(880, audio.currentTime);
  oscillator.frequency.setValueAtTime(1175, audio.currentTime + 0.12);
  gain.gain.setValueAtTime(0.0001, audio.currentTime);
  gain.gain.exponentialRampToValueAtTime(0.22, audio.currentTime + 0.03);
  gain.gain.exponentialRampToValueAtTime(0.0001, audio.currentTime + 0.55);

  oscillator.connect(gain);
  gain.connect(audio.destination);
  oscillator.start();
  oscillator.stop(audio.currentTime + 0.6);
}

startBtn.addEventListener('click', start);
resetBtn.addEventListener('click', reset);
modeBtns.forEach((button) => button.addEventListener('click', () => setMode(button.dataset.mode)));
inputs.forEach((input) => input.addEventListener('change', reset));

render();
