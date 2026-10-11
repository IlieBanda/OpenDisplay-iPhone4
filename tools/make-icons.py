#!/usr/bin/env python3
"""Package upstream's official artwork for the iOS 6 SpringBoard icon sizes."""
import pathlib
from PIL import Image, ImageDraw
root = pathlib.Path(__file__).resolve().parent.parent
source = Image.open(root / 'resources/OfficialIcon.png').convert('RGBA')
for name, size in [('LegacyIcon.png',57),('LegacyIcon@2x.png',114),('LegacyIcon-Small.png',29),('LegacyIcon-Small@2x.png',58)]:
    # Bake the legacy mask and gloss; UIPrerenderedIcon prevents double gloss.
    scale = 4
    mask = Image.new('L',(size*scale,size*scale),0)
    ImageDraw.Draw(mask).rounded_rectangle((0,0,size*scale-1,size*scale-1),radius=size*scale*10/57,fill=255)
    image = source.resize((size,size),Image.Resampling.LANCZOS)
    gloss = Image.new('RGBA',(size,size),(0,0,0,0))
    draw = ImageDraw.Draw(gloss)
    # Classic curved upper highlight, baked into the artwork for jailbreak themes.
    for y in range(size):
        for x in range(size):
            boundary = size*(0.42 + 0.13*(1-((x-size/2)/(size/2))**2))
            if y < boundary:
                gloss.putpixel((x,y),(255,255,255,int(100*(1-y/size))))
    image = Image.alpha_composite(image,gloss)
    image.putalpha(mask.resize((size,size),Image.Resampling.LANCZOS))
    image.save(root / 'resources' / name)
