"""Generate native widget picker fixtures. Run with Pillow and CairoSVG.

Install under Android/tools/; --resources overrides output for development.
Raster images and API31 RemoteViews preview layouts use the same three fixtures.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
from io import BytesIO
import argparse
import xml.etree.ElementTree as ET
# Homebrew's Cairo lives outside the default dyld search path on Apple Silicon.
import ctypes.util
_original_find_library = ctypes.util.find_library
if Path('/opt/homebrew/lib/libcairo.2.dylib').exists():
    ctypes.util.find_library = lambda name: '/opt/homebrew/lib/libcairo.2.dylib' if name == 'cairo' else _original_find_library(name)
import cairosvg
parser=argparse.ArgumentParser()
parser.add_argument('--resources',type=Path,default=Path(__file__).resolve().parents[1]/'app/src/main/res')
root=parser.parse_args().resources
fonts=[('/System/Library/Fonts/Supplemental/Arial.ttf','/System/Library/Fonts/Supplemental/Arial Bold.ttf'),('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf','/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf')]
regular,strong=next(pair for pair in fonts if all(Path(p).exists() for p in pair))
S=3
INK='#171D1A';SECONDARY='#667269';BG='#F3F5F1';CARD='#FDFEF9';TRACK='#DFE5DC'
COLORS={'claude':'#C57854','openai':'#369E80','gemini':'#558BE0','copilot':'#9874BF','opencode':'#7774CE','zai':'#D39843'}
def text(draw,x,y,value,size=12,color=INK,bold=False):draw.text((round(x*S),round(y*S)),value,font=ImageFont.truetype(strong if bold else regular,round(size*S)),fill=color)
def rectangle(draw,box,color,radius=0):draw.rounded_rectangle(tuple(round(v*S) for v in box),radius=round(radius*S),fill=color)
def logo(image,provider,x,y,size=20):
 a='{http://schemas.android.com/apk/res/android}'
 vector=ET.parse(root/'drawable'/f'provider_{provider}.xml').getroot()
 svg=ET.Element('svg',xmlns='http://www.w3.org/2000/svg',viewBox=f'0 0 {vector.get(a+"viewportWidth")} {vector.get(a+"viewportHeight")}')
 for path in vector.iter('path'):ET.SubElement(svg,'path',d=path.get(a+'pathData'),fill=COLORS[provider])
 try:
  data=cairosvg.svg2png(bytestring=ET.tostring(svg),output_width=size*S,output_height=size*S)
  glyph=Image.open(BytesIO(data)).convert('RGBA');image.alpha_composite(glyph,(round(x*S),round(y*S)))
 except ValueError:
  # Some Android arc flag compression is unsupported by the SVG parser.
  # Use an honest provider initial in the raster fallback; live widgets use the native vector.
  draw=ImageDraw.Draw(image);rectangle(draw,(x,y,x+size,y+size),COLORS[provider],size/2)
  text(draw,x+size*.27,y+size*.09,provider[0].upper(),size*.7,'#FFFFFF',True)
def refresh(draw,x,y,size=16):
 box=(x*S,y*S,(x+size)*S,(y+size)*S)
 draw.arc(box,start=40,end=325,fill='#276A50',width=2*S)
 draw.polygon(((x+size)*S,y*S,(x+size)*S,(y+size*.44)*S,(x+size*.56)*S,(y+size*.23)*S),fill='#276A50')
def bar(draw,x,y,w,value,provider):
 rectangle(draw,(x,y,x+w,y+7),TRACK,4);rectangle(draw,(x,y,x+w*value/100,y+7),COLORS[provider],4)
 mx=x+w*.5;draw.line((mx*S,(y-2)*S,mx*S,(y+9)*S),fill=CARD,width=4*S);draw.line((mx*S,(y-2)*S,mx*S,(y+9)*S),fill=INK,width=S)
def chart(draw,x,y,w,h,value,provider):
 for pct in (0,.25,.5,.75,1):draw.line((x*S,(y+h*(1-pct))*S,(x+w)*S,(y+h*(1-pct))*S),fill=TRACK,width=1)
 # Dashed steady pace; solid recorded fixture points occupy the elapsed half-cycle.
 for i in range(0,100,8):
  j=min(i+4,100);draw.line(((x+w*i/100)*S,(y+h*(1-i/100))*S,(x+w*j/100)*S,(y+h*(1-j/100))*S),fill=SECONDARY,width=S)
 samples=[0,value*.08,value*.2,value*.37,value*.55,value]
 xy=[((x+w*.5*i/(len(samples)-1))*S,(y+h*(1-v/100))*S) for i,v in enumerate(samples)]
 draw.line(xy,fill=COLORS[provider],width=2*S,joint='curve')
 end_x=.5+min(.5,(100-value)/(value*2)) if value>0 else 1
 end_y=min(100,value*2)
 for i in range(0,10,2):
  frac=i/10;frac2=(i+.7)/10
  draw.line(((x+w*(.5+(end_x-.5)*frac))*S,(y+h*(1-(value+(end_y-value)*frac)/100))*S,(x+w*(.5+(end_x-.5)*frac2))*S,(y+h*(1-(value+(end_y-value)*frac2)/100))*S),fill=COLORS[provider],width=S)
def canvas(w,h):
 image=Image.new('RGBA',(w*S,h*S));d=ImageDraw.Draw(image);rectangle(d,(0,0,w,h),BG,20);return image,d
image,d=canvas(260,104);rectangle(d,(0,0,260,104),CARD,20);logo(image,'claude',12,13,19)
text(d,39,14,'5-hour',12);text(d,164,12,'42% used',19,bold=True);bar(d,12,48,236,42,'claude');text(d,12,69,'Resets in 2h 45m',11)
image.save(root/'drawable-nodpi'/'single_limit_widget_preview.png',optimize=True)
image,d=canvas(300,240);rectangle(d,(0,0,300,240),CARD,20);logo(image,'claude',16,16,21);text(d,45,16,'Claude',16,bold=True);refresh(d,264,19,16);text(d,16,44,'Personal account',10,color=SECONDARY)
for y,label,value,reset in [(69,'5-hour',42,'2h 45m'),(139,'Weekly',68,'3d 12h')]:
 text(d,16,y,label,13);text(d,212,y,f'{value}% used',14,bold=True);bar(d,16,y+27,268,value,'claude');text(d,16,y+42,f'Resets in {reset}',10,color=SECONDARY)
text(d,16,214,'Updated just now',10,color=SECONDARY)
image.save(root/'drawable-nodpi'/'provider_limits_widget_preview.png',optimize=True)
image,d=canvas(380,550);text(d,16,14,'Meterkat',18,bold=True);refresh(d,345,20,17)
for index,(provider,name,values,cost,tokens) in enumerate([('claude','Claude',(42,68),'$2.41','124k'),('openai','OpenAI',(68,35),'$1.08','86k'),('opencode','OpenCode',(25,54),'$0.38','51k'),('zai','Z.ai',(38,61),'$0.76','72k')]):
 x=12+(index%2)*184;y=51+(index//2)*241;w=172
 rectangle(d,(x,y,x+w,y+232),CARD,16);logo(image,provider,x+12,y+11,18);text(d,x+37,y+12,name,14,bold=True);text(d,x+12,y+36,'Personal account',9,color=SECONDARY)
 for row,(label,value,reset) in enumerate(zip(('5-hour','Monthly' if provider == 'zai' else 'Weekly'),values,('2h 45m','3d 12h'))):
  ry=y+57+row*66;text(d,x+12,ry,label,10);text(d,x+100,ry,f'{value}% used',10,bold=True);chart(d,x+12,ry+19,w-24,27,value,provider);text(d,x+12,ry+50,f'Resets in {reset}',8,color=SECONDARY)
 text(d,x+12,y+187,'7d API estimate',9,color=SECONDARY);text(d,x+12,y+200,cost,12,bold=True);text(d,x+12,y+216,f'{tokens} tokens',9,color=SECONDARY)
text(d,16,526,'Updated just now · graphs or bars follow your settings',9,color=SECONDARY)
image.save(root/'drawable-nodpi'/'all_limits_widget_preview.png',optimize=True)
for name,w,h in [('single_limit',260,104),('provider_limits',300,240),('all_limits',380,550)]:
 (root/'layout'/f'{name}_widget_preview.xml').write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<ImageView xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent" android:layout_height="wrap_content"
    android:adjustViewBounds="true" android:scaleType="fitCenter"
    android:src="@drawable/{name}_widget_preview"
    android:contentDescription="@string/{name}_widget_description" />
''')
(root/'values'/'widget_descriptions.xml').write_text('''<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="single_limit_widget_description">A compact resizable limit with a bar or recorded usage graph, percentage, and reset time.</string>
    <string name="provider_limits_widget_description">All limits for your chosen account, with bars or recorded graphs and reset times.</string>
    <string name="all_limits_widget_description">A large resizable dashboard with provider accounts, limits, recorded graphs, and available API cost and token totals.</string>
</resources>
''')
