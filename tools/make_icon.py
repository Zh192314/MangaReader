"""生成 1024x1024 App 图标（无 alpha，符合 iOS 要求）。

跑法： python make_icon.py
输出： Icon-1024.png（同目录）
"""
from PIL import Image, ImageDraw

S = 1024
SS = 4                      # 4x 超采样后缩小，边缘更干净
W = S * SS

# ---- 背景：竖向渐变 #5FB2FF -> #2C7FE0 ----
top = (0x5F, 0xB2, 0xFF)
bottom = (0x2C, 0x7F, 0xE0)
img = Image.new("RGB", (W, W), bottom)
d = ImageDraw.Draw(img)
for y in range(W):
    t = y / (W - 1)
    # 轻微 ease，避免中段发灰
    t = t ** 0.92
    c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    d.line([(0, y), (W, y)], fill=c)

# ---- 底部一层更亮的斜向光 ----
glow = Image.new("L", (W, W), 0)
gd = ImageDraw.Draw(glow)
gd.ellipse([-W * 0.35, -W * 0.55, W * 0.95, W * 0.45], fill=46)
img = Image.composite(Image.new("RGB", (W, W), (0xFF, 0xFF, 0xFF)), img, glow)

d = ImageDraw.Draw(img)

# ---- 书：两页白色圆角矩形，中间留缝 ----
def rrect(box, r, fill):
    d.rounded_rectangle(box, radius=r, fill=fill)

cx, cy = W // 2, W // 2
page_w, page_h = int(W * 0.295), int(W * 0.455)
gap = int(W * 0.013)
radius = int(W * 0.030)
off = int(W * 0.012)        # 中缝错位，让书有立体感

left = [cx - gap - page_w, cy - page_h // 2, cx - gap, cy + page_h // 2]
right = [cx + gap, cy - page_h // 2, cx + gap + page_w, cy + page_h // 2]

# 书脊阴影（先画一层略暗的底，形成厚度）
rrect([left[0] + off, left[1] + off, left[2] + off, left[3] + off],
      radius, (0x1F, 0x63, 0xB4))
rrect([right[0] + off, right[1] + off, right[2] + off, right[3] + off],
      radius, (0x1F, 0x63, 0xB4))

rrect(left, radius, (0xFF, 0xFF, 0xFF))
rrect(right, radius, (0xFF, 0xFF, 0xFF))

# ---- 页面上的内容线（蓝色）----
line_c = (0x8F, 0xC4, 0xF2)
lw = max(2, int(W * 0.0085))
pad_x = int(page_w * 0.20)
for page in (left, right):
    y0 = page[1] + int(page_h * 0.26)
    step = int(page_h * 0.155)
    for k in range(3):
        y = y0 + k * step
        x1 = page[0] + pad_x
        x2 = page[2] - pad_x
        if k == 2:                       # 最后一行短一点
            x2 -= int(page_w * 0.18)
        d.line([(x1, y), (x2, y)], fill=line_c, width=lw)

# ---- 右上角红色小圆点（呼应 accentRed #F4442E）----
dr = int(W * 0.030)
dot_c = (cx + int(W * 0.262), cy - int(W * 0.300))
# 白色描边光环
d.ellipse([dot_c[0] - dr * 1.75, dot_c[1] - dr * 1.75,
           dot_c[0] + dr * 1.75, dot_c[1] + dr * 1.75], fill=(0xFF, 0xFF, 0xFF))
d.ellipse([dot_c[0] - dr, dot_c[1] - dr,
           dot_c[0] + dr, dot_c[1] + dr], fill=(0xF4, 0x44, 0x2E))

# ---- 缩回 1024，去掉 alpha ----
out = img.resize((S, S), Image.LANCZOS)
out = out.convert("RGB")
out.save("Icon-1024.png", "PNG", optimize=True)
print("wrote Icon-1024.png", out.size, out.mode)
