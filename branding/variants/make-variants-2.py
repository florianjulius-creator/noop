#!/usr/bin/env python3
"""Second batch of app-icon variants (07–12) for The Machine + contact sheet 2.

Run from the repo root:  python3 branding/variants/make-variants-2.py
"""
import math, os, subprocess

OUT = os.path.dirname(os.path.abspath(__file__))
DEFS = """
  <defs>
    <radialGradient id="bg" cx="50%" cy="42%" r="75%">
      <stop offset="0%" stop-color="#151b24"/><stop offset="70%" stop-color="#0b0f15"/><stop offset="100%" stop-color="#06080b"/>
    </radialGradient>
    <linearGradient id="mono" x1="0%" y1="100%" x2="100%" y2="0%">
      <stop offset="0%" stop-color="#22d3ee"/><stop offset="55%" stop-color="#2dd4bf"/><stop offset="100%" stop-color="#34d399"/>
    </linearGradient>
    <linearGradient id="gold" x1="0%" y1="100%" x2="100%" y2="0%">
      <stop offset="0%" stop-color="#B47A2B"/><stop offset="60%" stop-color="#E8B84B"/><stop offset="100%" stop-color="#F6DFA0"/>
    </linearGradient>
    <linearGradient id="dawn" x1="0%" y1="100%" x2="0%" y2="0%">
      <stop offset="0%" stop-color="#E0662F"/><stop offset="55%" stop-color="#E8B84B"/><stop offset="100%" stop-color="#F6DFA0"/>
    </linearGradient>
    <linearGradient id="deep" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#0F9D62"/><stop offset="100%" stop-color="#0B6B7A"/>
    </linearGradient>
    <linearGradient id="green" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#8FD86A"/><stop offset="100%" stop-color="#03E095"/>
    </linearGradient>
    <linearGradient id="blue" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#6FA8E8"/><stop offset="100%" stop-color="#3FA9C9"/>
    </linearGradient>
  </defs>
"""

def svg(body, bg='url(#bg)'):
    return f'''<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">{DEFS}
  <rect width="1024" height="1024" fill="{bg}"/>
{body}
</svg>
'''

V = {}

# 7. Zonsopkomst — half ring rising over a horizon line: the morning moment as a sunrise.
V['07-zonsopkomst'] = svg('''
  <path d="M 190 600 A 322 322 0 0 1 834 600" fill="none" stroke="#ffffff" stroke-opacity="0.07" stroke-width="64" stroke-linecap="round"/>
  <path d="M 190 600 A 322 322 0 0 1 760 372" fill="none" stroke="url(#dawn)" stroke-width="64" stroke-linecap="round"/>
  <path d="M 120 600 H 904" stroke="#F7F7FA" stroke-opacity="0.85" stroke-width="18" stroke-linecap="round"/>
  <path d="M 402 600 V 470 L 512 580 L 622 470 V 600" fill="none" stroke="#F7F7FA" stroke-width="52" stroke-linecap="round" stroke-linejoin="round"/>
''')

# 8. Hartslagring — the ring itself is drawn as an ECG trace: flat, spike, flat, around the circle.
def ecg_ring(cx, cy, r, spikes=3, amp=70, samples=720):
    pts = []
    for i in range(samples + 1):
        t = i / samples
        a = -math.pi / 2 + 2 * math.pi * t
        # one sharp QRS-like spike per third of the circle
        phase = (t * spikes) % 1.0
        d = 0.0
        if 0.44 < phase < 0.47: d = -0.35 * (phase - 0.44) / 0.03
        elif 0.47 <= phase < 0.50: d = -0.35 + 1.35 * (phase - 0.47) / 0.03
        elif 0.50 <= phase < 0.53: d = 1.0 - 1.45 * (phase - 0.50) / 0.03
        elif 0.53 <= phase < 0.56: d = -0.45 + 0.45 * (phase - 0.53) / 0.03
        rr = r + amp * d
        pts.append(f'{cx + rr * math.cos(a):.1f} {cy + rr * math.sin(a):.1f}')
    return 'M ' + ' L '.join(pts)
V['08-hartslagring'] = svg(f'''
  <path d="{ecg_ring(512, 512, 320)}" fill="none" stroke="url(#mono)" stroke-width="44" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="512" cy="512" r="70" fill="url(#mono)"/>
''')

# 9. Groen veld — solid deep-green ground, white M with the core dot punched out of the middle stroke.
V['09-groen-veld'] = svg('''
  <path d="M 262 740 V 300 L 512 560 L 762 300 V 740" fill="none" stroke="#F7F7FA" stroke-width="96" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="512" cy="700" r="60" fill="#F7F7FA"/>
''', bg='url(#deep)')

# 10. Drie bogen — recovery / strain / sleep as three nested open arcs, the Today overview in one glyph.
V['10-drie-bogen'] = svg('''
  <path d="M 262 720 A 330 330 0 1 1 762 720" fill="none" stroke="url(#green)" stroke-width="56" stroke-linecap="round"/>
  <path d="M 330 690 A 240 240 0 1 1 694 690" fill="none" stroke="url(#blue)" stroke-width="56" stroke-linecap="round"/>
  <path d="M 402 656 A 150 150 0 1 1 622 656" fill="none" stroke="#83A0B8" stroke-width="56" stroke-linecap="round"/>
  <circle cx="512" cy="600" r="40" fill="#F7F7FA"/>
''')

# 11. Scanlijnen — the M built from horizontal machine lines, denser at the bottom.
def scan_m():
    rows = []
    y = 300
    gap = 30
    while y <= 730:
        rows.append(f'M 262 {y} H 762')
        y += gap
    return ' '.join(rows)
V['11-scanlijnen'] = svg(f'''
  <clipPath id="mclip"><path d="M 216 760 V 260 H 316 L 512 470 L 708 260 H 808 V 760 H 708 V 430 L 512 640 L 316 430 V 760 Z"/></clipPath>
  <g clip-path="url(#mclip)">
    <path d="{scan_m()}" fill="none" stroke="url(#mono)" stroke-width="16" stroke-linecap="round"/>
  </g>
''')

# 12. Kroon — a flywheel with twelve notches (the machine) and a small solid M in the hub.
def notches(cx, cy, r1, r2, n=12):
    out = []
    for i in range(n):
        a = -math.pi / 2 + i * 2 * math.pi / n
        out.append(f'M {cx + r1 * math.cos(a):.1f} {cy + r1 * math.sin(a):.1f} L {cx + r2 * math.cos(a):.1f} {cy + r2 * math.sin(a):.1f}')
    return ' '.join(out)
V['12-kroon'] = svg(f'''
  <circle cx="512" cy="512" r="300" fill="none" stroke="url(#gold)" stroke-width="40"/>
  <path d="{notches(512, 512, 330, 386)}" stroke="url(#gold)" stroke-width="30" stroke-linecap="round"/>
  <path d="M 402 640 V 400 L 512 510 L 622 400 V 640" fill="none" stroke="#F7F7FA" stroke-width="54" stroke-linecap="round" stroke-linejoin="round"/>
''')

for name, body in V.items():
    path = os.path.join(OUT, f'{name}.svg')
    open(path, 'w').write(body)
    subprocess.run(['rsvg-convert', '-w', '512', '-h', '512', path, '-o', path[:-4] + '.png'], check=True)

cells = []
x0, y0, cell, gap = 60, 110, 300, 40
for i, name in enumerate(V):
    col, row = i % 3, i // 3
    x = x0 + col * (2 * cell + 3 * gap)
    y = y0 + row * (cell + 120)
    png = os.path.join(OUT, name + '.png')
    cells.append(f'''
  <clipPath id="sq{i}"><rect x="{x}" y="{y}" width="{cell}" height="{cell}" rx="66"/></clipPath>
  <clipPath id="ci{i}"><circle cx="{x + cell + gap + cell/2}" cy="{y + cell/2}" r="{cell/2}"/></clipPath>
  <image href="{png}" x="{x}" y="{y}" width="{cell}" height="{cell}" clip-path="url(#sq{i})"/>
  <image href="{png}" x="{x + cell + gap}" y="{y}" width="{cell}" height="{cell}" clip-path="url(#ci{i})"/>
  <text x="{x}" y="{y + cell + 44}" font-family="Helvetica, Arial" font-size="30" fill="#17181C">{name[:2]}. {name[3:]}</text>''')
W = x0 * 2 + 3 * (2 * cell + 3 * gap) - 3 * gap
H = y0 + 2 * (cell + 120) + 20
sheet = f'''<svg width="{W}" height="{H}" viewBox="0 0 {W} {H}" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
  <rect width="{W}" height="{H}" fill="#E9EBF0"/>
  <text x="{x0}" y="70" font-family="Helvetica, Arial" font-size="40" font-weight="bold" fill="#17181C">The Machine — icoonvarianten, blad 2 (iPhone-vierkant · Watch-rondje)</text>
  {''.join(cells)}
</svg>'''
sp = os.path.join(OUT, 'sheet2.svg')
open(sp, 'w').write(sheet)
subprocess.run(['rsvg-convert', '-w', str(W), sp, '-o', os.path.join(OUT, 'sheet2.png')], check=True)
print('ok', list(V))
