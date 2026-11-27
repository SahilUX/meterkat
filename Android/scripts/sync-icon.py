#!/usr/bin/env python3
"""Convert the existing Icon Composer SVG layers to an Android vector drawable."""
from pathlib import Path
import json
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[2]
icon = root / 'Icon/AppIcon.icon'
metadata = json.loads((icon / 'icon.json').read_text())
background = metadata['fill-specializations'][0]['value']['solid'].removeprefix('srgb:').split(',')
color = '#' + ''.join(f'{round(float(c)*255):02x}' for c in background[:3])
ns = '{http://www.w3.org/2000/svg}'

def shape(element):
    kind = element.tag.removeprefix(ns)
    a = element.attrib
    if kind == 'circle' or kind == 'ellipse':
        x, y = float(a['cx']), float(a['cy'])
        rx, ry = float(a.get('rx', a.get('r'))), float(a.get('ry', a.get('r')))
        path = f'M{x-rx},{y}a{rx},{ry} 0,1 0 {2*rx},0a{rx},{ry} 0,1 0 {-2*rx},0'
    elif kind == 'rect':
        x,y,w,h = (float(a.get(k,0)) for k in ('x','y','width','height'))
        r = float(a.get('rx',0))
        path = f'M{x+r},{y}h{w-2*r}a{r},{r} 0,0 1 {r},{r}v{h-2*r}a{r},{r} 0,0 1 {-r},{r}h{-w+2*r}a{r},{r} 0,0 1 {-r},{-r}v{-h+2*r}a{r},{r} 0,0 1 {r},{-r}z'
    elif kind == 'line':
        path = f'M{a["x1"]},{a["y1"]}L{a["x2"]},{a["y2"]}'
    else:
        return None
    return path

# Icon Composer groups are ordered front to back; Android paths paint back to front.
paths=[]
for group in reversed(metadata['groups']):
    for layer in group['layers']:
        svg=ET.parse(icon/'Assets'/layer['image-name']).getroot()
        def visit(e, inherited):
            attrs={**inherited,**e.attrib}
            path=shape(e)
            if path:
                style=f'android:fillColor="{attrs.get("fill","#000000")}"'
                if e.tag==ns+'line':
                    style=f'android:fillColor="#00000000" android:strokeColor="{attrs["stroke"]}" android:strokeWidth="{attrs["stroke-width"]}" android:strokeLineCap="{attrs["stroke-linecap"]}"'
                paths.append(f'        <path {style} android:pathData="{path}"/>')
            if e.tag not in (ns+'defs',ns+'clipPath'):
                for child in e:visit(child,attrs)
        visit(svg,{})
output=root/'Android/app/src/main/res/drawable'
(output/'ic_meterkat.xml').write_text('<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="108dp" android:height="108dp" android:viewportWidth="108" android:viewportHeight="108">\n    <group android:scaleX="0.66" android:scaleY="0.66" android:translateX="21" android:translateY="21">\n'+'\n'.join(paths)+'\n    </group>\n</vector>\n')
(root/'Android/app/src/main/res/values/icon_colors.xml').write_text(f'<resources><color name="icon_background">{color}</color></resources>\n')
print('Converted existing Meterkat icon layers:',len(paths),'shapes')
