expand = [0,4,8,13,17,22,26,31]

print("X68ColourLUT:")

for index in range(512):
    r =  index        & 7
    g = (index >> 3)  & 7
    b = (index >> 6)  & 7

    R = expand[r]
    G = expand[g]
    B = expand[b]

    x68 = (G << 11) | (R << 6) | (B << 1)

    print(f"    dc.w ${x68:04X}")
