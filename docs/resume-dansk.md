# Resumé: ydeevneanalyse af ZFS-pulje på Proxmox 9-klyngen
**Testperiode:** 21. april – 8. maj 2026
**Hosts målt:** m-p-proxmox-08, m-p-proxmox-05 (samt Windows-VM på -05)
**Omfang:** karakterisering af stock-Proxmox ZFS-on-LUKS pool under SQL Server-lignende workloads
**Fuld teknisk rapport:** `docs/findings-2026-04-25.md`

---

## Hovedkonklusioner

1. **Klyngens hosts er ikke ensartet hardware**, på trods af identisk softwarekonfiguration. m-p-proxmox-08 er udstyret med Samsung PM9A3 NVMe-diske; m-p-proxmox-05 har Micron 7400-serien. De to vendormodeller reagerer dramatisk forskelligt på samme ZFS-indstillinger — samme konfiguration giver op til 5× forskellig SQL transaction-commit-latens på de to maskiner.

2. **Klynge-ensartet ZFS-tuning er ikke en holdbar strategi.** Med standardindstillingen `zfs_dirty_data_max=4 GiB` opnås SQL log p99.9 på 44 ms på -05 (Micron) men 359 ms på -08 (Samsung) — samme ZFS, samme kerne, samme indstilling. Per-host konfigurationsstyring er nødvendig.

3. **Optimal tuning afhænger desuden af workload-mønster**, ikke kun af hardware. Kontinuerlig OLTP foretrækker en lille skrivebuffer (`dirty_data_max=256 MiB`); burst-workloads (checkpoint storms) foretrækker en stor (16 GiB) så bursten kan flushe som én blok i stedet for at forstyrre log-skrivninger. Ingen enkelt indstilling vinder begge regimer på samme host.

4. **Konkrete tuning-anbefalinger er udarbejdet** for hver kombination af vendor og workload-mønster (se `memory/tuning_recipes.md` i repository for drop-in `/etc/modprobe.d/zfs.conf`-snippets med forventede SLO-resultater).

5. **Pool-fragmentering bygger op hurtigere end forventet.** En 26-timers SQL Server-lignende workload på en pool med kun 7 % udnyttet kapacitet drev fragmenteringen fra 19 % til 37 %. Ydeevneeffekten viser sig primært i halelatens (p99/p99.9), ikke i gennemsnitlig throughput — hvilket er præcis det område, der har størst betydning for SQL Server-transaction-commit-SLO'er.

6. **Windows VM 26-timers endurance-test er gennemført** med stabile resultater (sql-log p99.9 = 11.5 ms over 26 timer, ingen drift). Et uventet resultat — VM'en præsterer bedre end host'en på samme hardware — afventer reproduktion under kontrollerede forhold før endelig konklusion drages.

7. **Det resterende ubesvarede spørgsmål er produktionens reelle workload-mønster.** Valget mellem de to tuning-recepter (lille vs stor skrivebuffer) afhænger af, om SQL Server-instanserne primært kører kontinuerlig OLTP eller har hyppige checkpoint-bursts. Dette skal måles på de faktiske produktionsdatabaser før tuning kan cementeres.

---

## Operationelle anbefalinger

1. **Konfigurer hver host individuelt** baseret på dens NVMe-vendor og forventet workload-mønster. Per-host `/etc/modprobe.d/zfs.conf` håndteret via konfigurationsstyring (Ansible per-node group_vars el.lign.) er nødvendig — én delt konfiguration fungerer ikke.

2. **Mål faktisk SQL Server-workload-mønster i produktion** (`sys.dm_io_virtual_file_stats` plus checkpoint-frekvens over en repræsentativ uge) før per-host valg af `zfs_dirty_data_max` cementeres.

3. **Tilføj hardware-vendor som en formel del af klyngens konfigurationsdokumentation.** Antagelsen om "ensartet hardware" er ikke korrekt og skal eksplicit håndteres af driftsteamet.

4. **Indfør kvartalsvis genscanning af pool-fragmentering** på alle produktionsknuder, så ydeevne-degradering opdages tidligt og kan håndteres proaktivt.

5. **På sigt:** sigt mod en ensartet NVMe-vendor-strategi ved næste hardwareudskiftning. Det vil signifikant simplificere konfigurationsstyringen og gøre fremtidige cluster-tests mere meningsfulde at sammenligne.

---

## Forsigtighedshensyn

- Anbefalingerne ovenfor er baseret på syntetiske workloads (`fio`); de bør valideres mod faktisk SQL Server-trafik før permanent applikation i produktion.
- Resultatet at "VM yder bedre end host" (punkt 6) er foreløbigt og bør reproduceres mindst tre gange under kontrollerede forhold før det indgår i langsigtede arkitekturbeslutninger.
- Linux-VM frameworket (`linux-vm/` i repository) er klar til brug men endnu ikke kørt; det vil komplettere fire-lags-sammenligningen (host → Linux VM → Windows VM → SQL Server) når en operationel testperiode er tilgængelig.
