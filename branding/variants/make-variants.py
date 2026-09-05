#!/usr/bin/env python3
"""Emit six app-icon variants for The Machine as 1024×1024 SVGs plus one contact sheet.

Run from the repo root:  python3 branding/variants/make-variants.py
Renders with rsvg-convert into branding/variants/*.png and sheet.png.
"""
import os, subprocess, textwrap

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

# 1. Ringen — the morning moment itself: recovery outside, sleep inside, core dot.
V['01-ringen'] = svg('''
  <circle cx="512" cy="512" r="330" fill="none" stroke="#ffffff" stroke-opacity="0.07" stroke-width="72"/>
  <circle cx="512" cy="512" r="228" fill="none" stroke="#ffffff" stroke-opacity="0.07" stroke-width="72"/>
  <path d="M 512 182 A 330 330 0 1 1 236 690" fill="none" stroke="url(#green)" stroke-width="72" stroke-linecap="round"/>
  <path d="M 512 284 A 228 228 0 1 1 300 372" fill="none" stroke="url(#blue)" stroke-width="72" stroke-linecap="round"/>
  <circle cx="512" cy="512" r="58" fill="url(#mono)"/>
''')

# 2. M met hartslag — the pulse IS the middle stroke of the M.
V['02-m-puls'] = svg('''
  <circle cx="512" cy="512" r="330" fill="none" stroke="#22d3ee" stroke-opacity="0.10" stroke-width="10"/>
  <path d="M 262 726 V 300" fill="none" stroke="url(#mono)" stroke-width="88" stroke-linecap="round"/>
  <path d="M 762 726 V 300" fill="none" stroke="url(#mono)" stroke-width="88" stroke-linecap="round"/>
  <path d="M 262 300 L 402 470 L 452 380 L 512 640 L 572 380 L 622 470 L 762 300"
        fill="none" stroke="url(#mono)" stroke-width="88" stroke-linecap="round" stroke-linejoin="round"/>
''')

# 3. Open gauge — the app's own 240° recovery arc with the M inside, core dot at the gap.
V['03-gauge-m'] = svg('''
  <path d="M 292 730 A 330 330 0 1 1 732 730" fill="none" stroke="#ffffff" stroke-opacity="0.08" stroke-width="54" stroke-linecap="round"/>
  <path d="M 292 730 A 330 330 0 1 1 796 700" fill="none" stroke="url(#gold)" stroke-width="54" stroke-linecap="round"/>
  <circle cx="512" cy="820" r="34" fill="url(#gold)"/>
  <path d="M 372 640 V 380 L 512 520 L 652 380 V 640" fill="none" stroke="#F7F7FA" stroke-width="64" stroke-linecap="round" stroke-linejoin="round"/>
''')

# 4. Titanium — gold flywheel, engraved M, no pulse. Quiet, expensive.
V['04-titanium'] = svg('''
  <circle cx="512" cy="512" r="352" fill="none" stroke="url(#gold)" stroke-width="26"/>
  <circle cx="512" cy="512" r="300" fill="none" stroke="#E8B84B" stroke-opacity="0.18" stroke-width="4"/>
  <path d="M 322 690 V 350 L 512 540 L 702 350 V 690" fill="none" stroke="url(#gold)" stroke-width="78" stroke-linecap="round" stroke-linejoin="round"/>
''', bg='url(#bg)')

# 5. Daglicht — light ground, ink M, one green pulse dot. The inverse of the family.
V['05-daglicht'] = svg('''
  <circle cx="512" cy="512" r="340" fill="none" stroke="#17181C" stroke-opacity="0.08" stroke-width="12"/>
  <path d="M 292 716 V 332 L 512 552 L 732 332 V 716" fill="none" stroke="#17181C" stroke-width="86" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="512" cy="700" r="46" fill="#0F9D62"/>
''', bg='#F3F1EA')

# 6. Eén lijn — the whole mark is one continuous ECG stroke that becomes an M.
V['06-een-lijn'] = svg('''
  <path d="M 110 600 H 250 L 292 600 V 372 L 512 592 L 732 372 V 600 H 780 L 812 520 L 846 680 L 878 600 H 914"
        fill="none" stroke="url(#mono)" stroke-width="70" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="512" cy="512" r="400" fill="none" stroke="#22d3ee" stroke-opacity="0.08" stroke-width="8"/>
''')

for name, body in V.items():
    path = os.path.join(OUT, f'{name}.svg')
    open(path, 'w').write(body)
    subprocess.run(['rsvg-convert', '-w', '512', '-h', '512', path, '-o', path[:-4] + '.png'], check=True)

# Contact sheet: each variant twice — iOS rounded square and watchOS circle — on a neutral ground.
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
  <text x="{x}" y="{y + cell + 44}" font-family="Helvetica, Arial" font-size="30" fill="#17181C">{i + 1}. {name[3:]}</text>''')
W = x0 * 2 + 3 * (2 * cell + 3 * gap) - 3 * gap
H = y0 + 2 * (cell + 120) + 20
sheet = f'''<svg width="{W}" height="{H}" viewBox="0 0 {W} {H}" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
  <rect width="{W}" height="{H}" fill="#E9EBF0"/>
  <text x="{x0}" y="70" font-family="Helvetica, Arial" font-size="40" font-weight="bold" fill="#17181C">The Machine — icoonvarianten (iPhone-vierkant · Watch-rondje)</text>
  {''.join(cells)}
</svg>'''
sp = os.path.join(OUT, 'sheet.svg')
open(sp, 'w').write(sheet)
subprocess.run(['rsvg-convert', '-w', str(W), sp, '-o', os.path.join(OUT, 'sheet.png')], check=True)
print('ok', list(V))
