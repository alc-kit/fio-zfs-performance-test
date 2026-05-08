# Resumé: ydeevneanalyse af ZFS-pulje på Proxmox 9-klyngen
**Testperiode:** 21. april – 8. maj 2026
**Hosts målt:** m-p-proxmox-08, m-p-proxmox-05 (samt Windows-VM på -05)
**Omfang:** karakterisering af stock-Proxmox ZFS-on-LUKS pool under SQL Server-lignende workloads
**Fuld teknisk rapport:** `docs/findings-2026-04-25.md`

---

## Driftsmæssig præmis

Klyngens servere er lejet hos en cloud-leverandør. Vi har **ingen indflydelse** på hvilke komponenter (specifikt NVMe-diskvendor) der placeres i den enkelte server, og hardware kan udskiftes uden varsel ved RMA. Sammen med kravet om **minimal varians på softwareniveau** på tværs af klyngen betyder dette, at en ensartet `/etc/modprobe.d/zfs.conf` skal anvendes på alle noder, selv om data viser, at per-host-tuning teknisk set ville give et bedre resultat. Den tekniske analyse handler derfor ikke om "hvordan tuner vi hver host optimalt", men om "givet den uundgåelige hardwarevarians, hvilken enkelt klyngedækkende konfiguration giver det mindst dårlige worst-case?".

---

## Hovedkonklusioner

1. **Klyngens hosts er ikke ensartet hardware**, på trods af identisk softwarekonfiguration. m-p-proxmox-08 er udstyret med Samsung PM9A3 NVMe-diske; m-p-proxmox-05 har Micron 7400-serien. De to vendormodeller reagerer dramatisk forskelligt på samme ZFS-indstillinger — samme konfiguration giver op til 5× forskellig SQL transaction-commit-latens på de to maskiner.

2. **Klyngedækkende tuning skal accepteres**, selv om det efterlader én vendor med suboptimal ydeevne. Den valgte indstilling skal undgå de værste tilfælde frem for at jagte vendor-specifikke optima. Standardindstillingen `zfs_dirty_data_max=4 GiB` er udelukket: den giver SQL log p99.9 på 359 ms på Samsung-hosts, hvilket er applikationssynligt og uacceptabelt.

3. **Anbefalet klyngedækkende konfiguration:**
   ```
   options zfs zfs_arc_max=274877906944       # 256 GiB
   options zfs zfs_dirty_data_max=268435456   # 256 MiB
   ```
   Resultat per vendor:
   - Micron-hosts: SQL log p99.9 = **16 ms** (deres optimum)
   - Samsung-hosts: SQL log p99.9 = **38 ms** (deres optimum, men stadig 2,4× ringere end Micron)
   
   38 ms p99.9 er inden for typiske SQL Server OLTP SLO-grænser (≤ 50 ms er almindeligt), så Samsung-hosts er driftsmæssigt anvendelige — bare ikke lige så hurtige som Micron. Dette er prisen for klyngeensartethed.

4. **Optimal tuning afhænger desuden af workload-mønster.** Kontinuerlig OLTP foretrækker en lille skrivebuffer; burst-workloads (checkpoint storms) foretrækker en stor. Ovenstående anbefaling er optimeret for kontinuerlig OLTP. Ved `zfs_dirty_data_max=256 MiB` rammer burst-workloads ~70 ms p99.9 mod ~15 ms ved den højere indstilling — accepteret som en del af kompromiset.

5. **Pool-fragmentering bygger op hurtigere end forventet.** En 26-timers SQL Server-lignende workload på en pool med kun 7 % udnyttet kapacitet drev fragmenteringen fra 19 % til 37 %. Ydeevneeffekten viser sig primært i halelatens (p99/p99.9), ikke i gennemsnitlig throughput — hvilket er præcis det område, der har størst betydning for SQL Server-transaction-commit-SLO'er.

6. **Windows VM 26-timers endurance-test er gennemført** med stabile resultater (sql-log p99.9 = 11.5 ms over 26 timer, ingen drift). Et uventet resultat — VM'en præsterer bedre end host'en på samme hardware — afventer reproduktion. Det er sandsynligt at dette uventede gap forsvinder når den anbefalede klyngedækkende konfiguration deployes, da host'en så bringes ind i samme regime som VM'en allerede befandt sig i.

7. **Det resterende ubesvarede spørgsmål er produktionens reelle workload-mønster.** Hvis SQL Server-trafikken viser sig at være domineret af checkpoint-bursts snarere end kontinuerlig OLTP, kan den anbefalede klyngedækkende konfiguration revurderes; men givet at "default 4 GiB" er udelukket pga. Samsung-regressionen, vil valget under alle omstændigheder være et kompromis.

---

## Operationelle anbefalinger

1. **Deploy den ensartede klyngekonfiguration** i `/etc/modprobe.d/zfs.conf` på alle noder via standard konfigurationsstyring (Ansible / Salt / Puppet). Vendor-specifikke indstillinger skal udtrykkeligt undgås for at bevare driftens enkelhed.

2. **Mål faktisk SQL Server-workload-mønster i produktion** (`sys.dm_io_virtual_file_stats` plus checkpoint-frekvens over en repræsentativ uge). Hvis trafikken viser sig at være burst-domineret kan klyngevalget revurderes; resultaterne er bedre baseret på data end på antagelse.

3. **Tilføj hardware-vendor til klyngens konfigurationsdokumentation som observeret tilstand**, ikke som styret tilstand. `nvme list`-output på hver node bør indsamles og registreres så driftsteamet er opmærksom på vendor-fordelingen, selv om man ikke kan ændre den.

4. **Indfør kvartalsvis genscanning af pool-fragmentering** på alle produktionsknuder, så ydeevne-degradering opdages tidligt og kan håndteres proaktivt (typisk via en kontrolleret rebalancering eller — på langt sigt — pool-rekreering).

5. **Reproducer Windows VM-resultatet** under kontrollerede forhold (mindst tre kørsler) før det indgår i arkitekturbeslutninger. Givet at klyngedækkende tuning forventes at lukke gabet, bør reproduktionen ske *efter* deploy af den nye konfiguration.

6. **Når Linux-VM frameworket (`linux-vm/`) køres**, vil fire-lags-sammenligningen (host → Linux VM → Windows VM → SQL Server) blive komplet og isolere OS- og filsystemskontributionen fra virtio-/qemu-stakken. Afventer en operationel testperiode på en stille klyngenode.

---

## Forsigtighedshensyn

- Anbefalingerne ovenfor er baseret på syntetiske workloads (`fio`); de bør valideres mod faktisk SQL Server-trafik før permanent applikation i produktion.
- Resultatet at "VM yder bedre end host" (punkt 6) er foreløbigt og bør reproduceres mindst tre gange under kontrollerede forhold før det indgår i langsigtede arkitekturbeslutninger.
- Den driftsmæssige beslutning om klyngeensartethed (i stedet for per-host-tuning) er truffet med åbne øjne: vi accepterer at Samsung-hosts kører med en 2,4× højere log-latens end Micron-hosts under den anbefalede konfiguration, fordi den driftsmæssige forenkling vurderes vigtigere end den vendor-specifikke optimering.
