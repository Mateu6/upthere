# A two-minute ambient pad, synthesised here, so the demo shows no one else's music.
import math, struct, wave
RATE, SECONDS = 44100, 120
chords = [[220.0, 261.63, 329.63, 392.0], [174.61, 220.0, 261.63, 329.63], [196.0, 246.94, 293.66, 392.0], [164.81, 207.65, 246.94, 329.63]]
BAR = 6.0
out = wave.open("pad.wav", "wb"); out.setnchannels(2); out.setsampwidth(2); out.setframerate(RATE)
frames = bytearray()
for n in range(RATE * SECONDS):
    t = n / RATE
    i = int(t // BAR); x = (t % BAR) / BAR
    a, b = chords[i % 4], chords[(i + 1) % 4]
    fade = min(1, max(0, (x - 0.8) / 0.2))  # crossfade into the next chord over the last fifth of the bar
    v = 0.0
    for f1, f2 in zip(a, b):
        v += (1 - fade) * math.sin(2 * math.pi * f1 * t) + fade * math.sin(2 * math.pi * f2 * t)
        v += 0.3 * ((1 - fade) * math.sin(2 * math.pi * f1 * 2.003 * t) + fade * math.sin(2 * math.pi * f2 * 2.003 * t))
    swell = 0.75 + 0.25 * math.sin(2 * math.pi * t / 8)
    pulse = 0.55 + 0.45 * (math.sin(2 * math.pi * t * 2) ** 8)  # a soft 120 bpm pulse so the sound bars move
    env = min(1, t / 3) * min(1, (SECONDS - t) / 4)
    s = v / 5.2 * swell * pulse * env * 0.6
    l = int(max(-1, min(1, s)) * 32000); r = int(max(-1, min(1, s * 0.96)) * 32000)
    frames += struct.pack("<hh", l, r)
out.writeframes(bytes(frames)); out.close()
