; trig_tab.inc — wygenerowane przez tools/trig_tab.py; nie edytować
; bity 2/pi (bit j ma wagę 2^(63 - j)) do redukcji argumentu sin/cos/tan
align 8
rt_2opi:
    dq 0x0000000000000000, 0xa2f9836e4e441529
    dq 0xfc2757d1f534ddc0, 0xdb6295993c439041
    dq 0xfe5163abdebbc561, 0xb7246e3a424dd2e0
    dq 0x06492eea09d1921c, 0xfe1deb1cb129a73e
    dq 0xe88235f52ebb4484, 0xe99c7026b45f7e41
    dq 0x3991d639835339f4, 0x9c845f8bbdf9283b
    dq 0x1ff897ffde05980f, 0xef2f118b5a0a6d1f
    dq 0x6d367ecf27cb09b7, 0x4f463f669e5fea2d
    dq 0x7527bac7ebe5f17b, 0x3d0739f78a5292ea
    dq 0x6bfb5fb11f8d5d08, 0x56033046fc7b6bab
    dq 0xf0cfbc209af4361d, 0xa9e391615ee61b08
    dq 0x6599855f14a06840, 0x8dffd8804d732731
; pi/2 (80 bitów x87: mantysa, wykładnik 16383)
rt_pio2:
    dq 0xc90fdaa22168c235
    dw 0x3fff
