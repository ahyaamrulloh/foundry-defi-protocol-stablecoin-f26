# foundry-defi-stablecoin

Protokol stablecoin terdesentralisasi yang dibangun di atas Foundry. Protokol ini memungkinkan pengguna untuk mencetak stablecoin DSC (Decentralized Stable Coin) yang di-peg ke USD dengan menjaminkan aset kripto seperti wETH dan wBTC.

## Deskripsi

`foundry-defi-stablecoin` adalah implementasi protokol stablecoin berbasis collateral yang terinspirasi dari MakerDAO/DAI. Protokol ini dirancang untuk selalu **overcollateralized**, artinya total nilai jaminan harus selalu lebih besar dari total DSC yang dicetak. Jika nilai jaminan turun di bawah ambang batas yang ditentukan, posisi pengguna dapat dilikuidasi oleh liquidator eksternal untuk menjaga kesehatan protokol.

Protokol ini dibangun dengan filosofi:
- **Overcollateralized** — nilai collateral selalu lebih besar dari DSC yang beredar
- **Algoritmik** — mekanisme mint dan burn diatur sepenuhnya oleh smart contract
- **Terdesentralisasi** — tidak ada kontrol terpusat atas protokol

## Arsitektur Kontrak

Protokol ini terdiri dari dua kontrak utama yang bekerja secara bersama-sama:

### 1. `DecentralizedStableCoin.sol`
Kontrak ERC20 yang merepresentasikan token stablecoin DSC. Kontrak ini hanya bisa di-mint dan di-burn oleh `DSCEngine`, sehingga supply DSC sepenuhnya dikontrol oleh logika protokol.

### 2. `DSCEngine.sol`
Kontrak inti yang mengatur seluruh logika protokol, meliputi:

- **Deposit Collateral** — pengguna menyetor wETH atau wBTC sebagai jaminan
- **Mint DSC** — pengguna mencetak DSC maksimal 50% dari nilai collateral (200% collateralization ratio)
- **Redeem Collateral** — pengguna menarik kembali collateral selama health factor tetap aman
- **Burn DSC** — pengguna membakar DSC untuk mengurangi utang
- **Liquidate** — liquidator dapat melikuidasi posisi undercollateralized dan mendapatkan bonus 10% dari collateral

Health factor dihitung berdasarkan rasio nilai collateral terhadap DSC yang dicetak. Jika health factor pengguna jatuh di bawah `1e18`, posisi mereka dapat dilikuidasi.

## Invariant Utama

Protokol ini diuji menggunakan **stateful fuzz testing (invariant test)** dengan Foundry untuk memastikan properti berikut selalu terpenuhi dalam kondisi apapun:

```
Total Nilai Collateral >= Total DSC yang Beredar
```

Pengujian mencakup skenario deposit, mint, redeem, liquidasi, hingga simulasi price crash dari oracle.

## Teknologi

- [Foundry](https://getfoundry.sh/) — framework pengembangan dan pengujian smart contract
- [Chainlink Price Feed](https://docs.chain.link/data-feeds) — oracle harga untuk wETH dan wBTC
- [OpenZeppelin](https://openzeppelin.com/contracts/) — library kontrak ERC20 dan keamanan