# BBFS Shinobi Website Synced V1

File ini adalah hasil sinkronisasi **tanpa merusak file lama**.

## Prinsip kerja

- File ZIP/HTML lama tidak ditimpa.
- Website visual tetap memakai layout/background dari screenshot/prototype Shinobi.
- Data database ditambahkan melalui `data.js`.
- `index.html` hanya disisipi layer sinkronisasi non-destruktif.
- File asli disimpan sebagai `index.original.html`.

## Sumber data

Database yang dipakai:

```text
bbfs_database_v1_engine.sqlite
```

Ringkasan database:

| Item | Nilai |
|---|---:|
| Pasaran aktif | 57 |
| Result rows | 86933 |
| Tanggal awal | 2022-01-02 |
| Tanggal akhir | 2026-06-08 |

## Data yang disinkronkan ke website

- Result terbaru dari `result_draws`
- BBFS dari `bbfs_predictions` jika tersedia
- Poltar dari `poltar_predictions` jika tersedia
- Ranking 2D dari `ranking_2d_predictions`
- Ranking 3D dari `ranking_3d_predictions`
- Arsip ringkas dari latest result per pasaran

## Catatan

Ini masih file website statis yang membawa data hasil export database di `data.js`. Untuk produksi final, sinkronisasi ideal tetap lewat Laravel/Blade/API + PostgreSQL.
