#!/usr/bin/env python3
"""Generate the English-only iPlay GitHub Pages site; no runtime dependencies."""
from pathlib import Path
import json
from html import escape as e

ROOT = Path(__file__).resolve().parents[1]
SITE = ROOT / 'site'
d = json.loads((SITE / 'content.json').read_text())['en']

BASE = 'https://nightvibes33.github.io/iPlay/'
REPO = 'https://github.com/NightVibes33/iPlay'
BUILD = REPO + '/actions/workflows/ios-unsigned-ipa.yml?query=branch%3Atemp%2Fios-carplay-headunit'
NOTES = REPO + '/blob/temp/ios-carplay-headunit/iOS/README.md'
INSTALL = REPO + '/tree/temp/ios-carplay-headunit/iOS'

pics = ''.join(
    f'<figure><a href="./assets/{pic}.png"><img src="./assets/{pic}.png" width="1920" height="1080" loading="lazy" alt="{e(cap)}"></a><figcaption>{e(cap)}</figcaption></figure>'
    for pic, cap in zip(['home', 'settings'], d['captions'])
)

(SITE / 'index.html').write_text(f'''<!doctype html>
<html lang="en" dir="ltr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>iPlay · {e(d['download'])}</title><meta name="description" content="{e(d['intro'])}"><meta name="theme-color" content="#0c121c">
<link rel="icon" href="./assets/icon.png"><link rel="stylesheet" href="./assets/site.css"><link rel="canonical" href="{BASE}">
<meta property="og:title" content="iPlay — CarPlay head unit on iPhone"><meta property="og:description" content="{e(d['promise'])}"><meta property="og:image" content="{BASE}assets/home.png"><meta property="og:url" content="{BASE}"><meta property="og:type" content="website">
</head><body><main>
<header><a class="brand" href="./"><img src="./assets/icon.png" width="56" height="56" alt=""><span><strong>iPlay</strong><small>{e(d['tag'])}</small></span></a><nav class="languages" aria-label="Language"><a href="./" lang="en" hreflang="en" dir="auto" aria-current="page">English</a></nav></header>
<section class="hero"><span class="badge">{e(d['badge'])}</span><h1>{e(d['title']).replace(chr(10),'<br>')}</h1><p class="intro">{e(d['intro'])}</p><div class="actions"><a class="button" href="{BUILD}">{e(d['download'])} <span aria-hidden="true">↓</span></a><a class="button secondary" href="#install">{e(d['install'])}</a></div><p class="promise">{e(d['promise'])}</p><p class="note">{e(d['requires'])}</p><p class="note support-scope"><strong>{e(d['supportScope'])}</strong></p></section>
<section class="gallery"><h2>{e(d['gallery'])}</h2><div class="screens">{pics}</div></section>
<div class="grid"><section class="card" id="install"><span class="eyebrow">01</span><h2>{e(d['setup'])}</h2><ol>{''.join('<li>'+e(x)+'</li>' for x in d['steps'])}</ol><p class="note">{e(d['bssid'])}</p><a href="{INSTALL}">{e(d['adb'])} ↗</a></section>
<section class="card"><span class="eyebrow">02</span><h2>{e(d['whats'])}</h2><ul>{''.join('<li>'+e(x)+'</li>' for x in d['features'])}</ul><a href="{NOTES}">{e(d['notes'])} ↗</a><h3>{e(d['compat'])}</h3><p>{e(d['compatText'])}</p></section></div>
<section class="card updates"><div><h2>{e(d['follow'])}</h2><p>{e(d['followText'])}</p></div><a class="button secondary" href="{REPO}">{e(d['telegram'])} ↗</a></section>
<section class="signing"><h2>{e(d['update'])}</h2><p>{e(d['updateText'])}</p></section>
<footer><nav><a href="{REPO}/blob/main/docs/PRIVACY.md">{e(d["privacy"])}</a><a href="{REPO}">{e(d['source'])}</a><a href="{NOTES}">{e(d['notes'])}</a><a href="{REPO}/issues">{e(d['feedback'])}</a></nav><p>{e(d['footer'])}</p></footer>
</main></body></html>''')

print('Generated English iPlay page')
