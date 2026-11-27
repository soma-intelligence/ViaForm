# ViaForm Mac : synthèse des 5 directions d'interface

Cible : app macOS native, SwiftUI au maximum, logique dans le cœur Rust (`core/`, `generative/`, `engines/solidcraft`, `engines/pcbcraft`, `sim/`) exposée par l'ABI C de `bridge/`. Pas d'Electron. Les huit ateliers : Design, Generative, Mechanics (appelé "Assembly" dans les maquettes), Electronics, Simulation, Training, Render, Manufacture.

Maquettes : `docs/design-proposals/*.html` (ouvrir dans un navigateur, cliquer les ateliers ou `Cmd+1` à `Cmd+8`). Captures à 1600 x 1000 : `screens/<maquette>-<n>-<atelier>.png` (40 captures) et une planche par maquette `screens/<maquette>-overview.png`.

## 1. État des maquettes

| Maquette | État trouvé à la reprise | Ce qui a été fait | 8 états |
|---|---|---|---|
| A. Ribbon Pro | Complète, version Mac | Nom d'un produit tiers retiré de la légende | oui |
| B. Direct Canvas | Tronquée au milieu du script (vues écrites, aucun rendu ni interaction) | Code d'assemblage écrit : barre d'outils segmentée, rail d'outils, inspecteur Items / History, carte de lignée, menu flottant, file de tâches, cube de vue, trièdre, `Cmd+1..8`, boutons "Update" qui purgent les badges périmés | oui |
| C. Product Pipeline | Complète, version Mac | Aucune correction nécessaire | oui |
| D. Split Studio | Complète, cube de vue cassé (lettres géantes en surimpression) | Échelle du texte du cube corrigée | oui |
| E. Flow Graph | Le fichier en place était l'ancienne version Electron ; la version Mac existait en 4 morceaux non assemblés (sans code d'application) | Assemblée, code d'application écrit : graphe du projet (10 nœuds, arêtes typées, lignée en surbrillance, arête de retour "crash loads"), barre latérale, bandeau d'outils par atelier, inspecteur Entrées / Sorties, file d'exécution animée, barre de commande façon Spotlight (`Cmd+K`), modes 3D / Split / Flow, "Update downstream". Cube de vue démiroité | oui |

Aucun caractère tiret cadratin, aucun nom ni logo de produit tiers dans les fichiers. Les cinq pages chargent sans erreur JavaScript.

## 2. Notes sous trois angles

Notes sur 10. Ressemblance = sensation Fusion 360 / Shapr3D rendue en app Mac (densité, chrome, viewport). Flux = l'enchaînement génératif, mécanique, électronique, simulation, entraînement, rendu, fabrication se lit comme un seul produit (lignée, périmés, sélection liée, file de tâches). Faisabilité = effort en SwiftUI macOS 14+ sur l'existant `apple/` et `bridge/`, risque AppKit, usage sur un MacBook 13 pouces.

| Maquette | Ressemblance | Flux | Faisabilité | Total |
|---|---|---|---|---|
| A. Ribbon Pro | 9 | 6 | 8 | 23 |
| B. Direct Canvas | 8 | 6 | 9 | 23 |
| C. Product Pipeline | 8 | 9 | 7 | **24** |
| D. Split Studio | 7 | 7 | 5 | 19 |
| E. Flow Graph | 7 | 9 | 5 | 21 |

### A. Ribbon Pro
Le plus proche de Fusion : sélecteur d'atelier en tête de barre d'outils, ruban d'onglets à panneaux groupés, arbre de navigation unique pour tout le projet (corps, cartes, scénarios, entraînements), timeline en bas, onglet vert "Finish". Le flux passe par des badges de dépendance dans l'arbre et une pastille de tâches ; on comprend ce qui est périmé mais pas pourquoi ni dans quel ordre. Faisabilité bonne : `DeskRootView.swift` est déjà un ruban + arbre + timeline, c'est surtout une généralisation à 8 ateliers. Défaut : le ruban mange 80 px de hauteur, serré sur 13 pouces.

- SwiftUI : `WindowGroup` > `NavigationSplitView(sidebar: BrowserTree, detail: VStack { RibbonView(workspace), ZStack { Viewport, ViewCube, NavBar }, TimelineBar })` + `.inspector { InspectorView }` ; `ToolbarItem(.navigation) { WorkspaceMenu }`.
- Réutilise : `DeskRootView`, `DeskPanels` (MarkingMenu, ToolboxSearch), `Viewport`, `ViewCube`, `PCBCanvas`, `GenerateView`, `SimulationView`.
- Bridge à ajouter : `vf_project_tree` (arbre multi-domaines), `vf_project_deps` (badges), `vf_job_*` (file de tâches).

### B. Direct Canvas
Le plus proche de Shapr3D : viewport plein cadre, rail d'outils flottant, contrôle segmenté des 8 ateliers au centre de la barre d'outils, menu contextuel en pilule près de la sélection, inspecteur unique avec une bande de lignée (Study, Frame, Joints, Board, Flight, Policy, Render, Make) et un message "ce qui est périmé et pourquoi" avec action. Le plus simple et le plus Mac. Faiblesse : la lignée est linéaire, elle ne montre pas les vraies dépendances croisées (la carte alimente à la fois la simulation et l'export).

- SwiftUI : `NavigationStack` sans sidebar ; `ZStack { Viewport, ToolRail (.ultraThinMaterial), ContextPill (positionnée par la projection de la sélection), ActivityPanel }` + `.inspector { LineageStrip, Picker(Items/History), ItemsList, SelectionCard }` ; `ToolbarItem(.principal) { Picker(.segmented) }`.
- Réutilise : `Viewport`, `Picking` (position écran de la pilule), `ViewCube`, `CommonViews`.
- Bridge à ajouter : `sc_selection_screen_anchor` (ou calcul côté Swift avec `OrbitCamera`), `vf_project_lineage(node)`, `vf_job_*`.

### C. Product Pipeline
Outils façon Fusion, avec une rangée de 8 étapes dans la barre d'outils (Design, Generate, Assemble, Electronics, Simulate, Train, Render, Make), chacune avec son état (à jour, périmé, en cours, échec) et ce qu'elle consomme et produit. Un seul viewport partagé, les étapes changent outils et surimpressions ; panneau "Flow" (consomme / produit / sélection liée) dans l'inspecteur ; graphe de dépendances en popover. Meilleur compromis : le flux est visible en permanence sans voler de place au viewport. Risque : 8 étapes avec état dans la barre d'outils demandent une vue personnalisée (pas un `Picker` standard) et un repli en menu sous 1440 px.

- SwiftUI : `NavigationSplitView(sidebar: StageSidebar, detail: VStack { StageToolStrip, ZStack { Viewport, StageOverlay } , StageBottomPanel })` + `.inspector { FlowSection, LinkedSelection, StageProperties }` ; `ToolbarItem(.principal) { PipelineBar }` avec `ViewThatFits` pour le repli ; `.popover { DependencyGraph }`.
- Réutilise : tout l'existant `Desk` + `Generate*` + `Sim*` + `PCBCanvas`.
- Bridge à ajouter : `vf_project_status` (état des 8 étapes), `vf_project_io(stage)` (consomme / produit), `vf_project_update(stage)`, `vf_job_*`.

### D. Split Studio
Le 3D toujours visible, un panneau 2D ancré à côté (schéma ou PCB à côté de la carte montée, courbes de récompense à côté du drone qui vole, grille de variantes à côté de la variante choisie, file de rendu à côté de l'aperçu), avec sondage croisé entre les deux. Très fort en électronique et en entraînement, moins utile en Design pur. Le plus coûteux : deux vues Metal vivantes, un trait de sondage qui traverse le séparateur, `HSplitView` peu fiable en SwiftUI (repli `NSSplitViewController`).

- SwiftUI : `NavigationSplitView(sidebar, detail: SplitHost { Viewport3D | DisciplinePane })` où `SplitHost` = `NSViewControllerRepresentable` sur `NSSplitViewController` ; surimpression `Canvas` pour le trait de sondage.
- Réutilise : `Viewport`, `PCBCanvas`, `DeskPCBView`, `GenerateResults`, `SimulationView`.
- Bridge à ajouter : `vf_probe(domain, id)` (correspondance composant PCB vers pièce 3D et inversement), `vf_link_*` existant, `vf_job_*`.

### E. Flow Graph
Chaque artefact est un nœud typé (esquisse, corps, étude générative, assemblage, schéma, PCB, scénario, entraînement, rendu, export) relié par des arêtes typées (géométrie, carte, physique, politique) ; le graphe est un tiroir sous le 3D, ou plein écran ; cliquer un nœud ouvre son atelier ; file d'exécution des longs calculs Rust ; barre de commande façon Spotlight avec plan en étapes. Le flux le plus clair et le plus honnête (on voit l'arête de retour "crash loads" de la simulation vers l'étude). Coûteux : éditeur de graphe à écrire (disposition, routage des arêtes, zoom, sélection) en `Canvas`, et le tiroir de 300 px est lourd en usage courant.

- SwiftUI : `NavigationSplitView(sidebar: ProjectList, detail: VStack { DisciplineStrip, Viewport, FlowDrawer(Canvas) })` + `.inspector { NodeInspector, RunQueue }` ; `.searchable` ou panneau `NSPanel` pour la barre de commande.
- Réutilise : `Viewport`, les vues d'atelier existantes dans le détail.
- Bridge à ajouter : `vf_project_graph` (nœuds + arêtes + états), `vf_project_update_downstream(node)`, `vf_job_*`, `vf_assistant_plan` (optionnel, côté Swift possible).

## 3. Recommandation

**Base C (Product Pipeline), habillée du chrome de A, avec trois greffes : le menu contextuel en pilule et l'inspecteur de B, le graphe de E en popover / tiroir à la demande, le panneau ancré de D seulement pour Electronics et Training.**

Pourquoi : C met le flux entre ateliers en permanence sous les yeux (exigence centrale) sans sacrifier le viewport ; le chrome de A existe déjà dans `DeskRootView.swift` (ruban, arbre, timeline), donc l'effort part de l'existant ; B apporte la légèreté Shapr3D là où le ruban est trop lourd ; E reste la vue de vérité pour les dépendances croisées, mais en vue secondaire ; D n'est payé que là où il rapporte (carte montée dans le corps, courbes à côté du vol).

### Hiérarchie SwiftUI de l'hybride

```
ViaFormApp
└─ WindowGroup(for: ProjectDocument)            // DocumentGroup plus tard
   └─ ProjectWindow (@State ProjectModel, JobQueue)
      ├─ .toolbar
      │   ├─ .navigation : SidebarToggle, Undo/Redo
      │   ├─ .principal  : PipelineBar (8 StageChip : icône SF Symbol, état, compteur périmés)
      │   │                 ViewThatFits -> repli en Menu sous 1440 px
      │   └─ .primaryAction : JobsButton (.popover JobQueueView), GraphButton (.popover FlowGraphView), Share
      ├─ NavigationSplitView
      │   ├─ sidebar : BrowserTree (List + OutlineGroup, badges de dépendance, sélection liée)
      │   └─ detail  : VStack(spacing: 0)
      │       ├─ StageRibbon(stage)              // généralise le ruban de DeskRootView, 48 px, .bar material
      │       ├─ StageCanvas(stage)
      │       │   ├─ Viewport (Metal, existant) ou PCBCanvas / OutcomeGrid / TrainingCharts selon l'étape
      │       │   ├─ ContextPill (.ultraThinMaterial, ancrée sur la sélection via Picking + OrbitCamera)
      │       │   ├─ ViewCube, NavBar, StaleBanner ("Run 12 a volé Frame v11 : Re-run")
      │       │   └─ DockedPane (Electronics, Training seulement ; NSSplitViewController en repli)
      │       └─ TimelineBar (Design) / RunScrubber (Simulation, Training)
      └─ .inspector(isPresented:) : InspectorView
          ├─ FlowSection (consomme / produit / états)
          ├─ LinkedSelectionCard
          └─ StageProperties (Form + LabeledContent)
   + Commands { CommandMenu("Stage") : Cmd+1..8, Cmd+K palette, Update downstream (Cmd+Shift+U) }
```

Ce qui est délicat en SwiftUI macOS 14+ et le repli :
- Ruban dense et barre de pipeline personnalisée : vues SwiftUI simples, mais `ToolbarItem(.principal)` limite la largeur ; si besoin, `NSToolbar` via `NSViewRepresentable`.
- Panneau ancré redimensionnable : `HSplitView` perd la taille et ne se replie pas proprement ; `NSSplitViewController` enveloppé.
- Pilule contextuelle qui suit la sélection 3D : position calculée à chaque image depuis la caméra ; publier la position via un `@Observable` throttlé pour ne pas reconstruire toute la vue.
- Graphe : `Canvas` + `gesture` pour le rendu et le déplacement ; disposition calculée côté Rust (`vf_project_graph` renvoie les positions) pour rester déterministe.
- Raccourcis et menus : `Commands` couvre tout, pas besoin d'AppKit.

### Bridge à ajouter (`bridge/src`, `bridge/include`)

Convention existante gardée : poignée opaque, JSON en entrée et en sortie, chaînes libérées par `sc_string_free`.

| Fonction | Rôle | Ateliers |
|---|---|---|
| `vf_project_new/free`, `vf_project_graph` | Graphe des artefacts (nœuds, arêtes typées, révisions, état à jour / périmé / en cours / échec) | tous |
| `vf_project_status`, `vf_project_io(stage)` | État des 8 étapes, ce que chacune consomme et produit | barre de pipeline, inspecteur |
| `vf_project_update(node)`, `vf_project_update_downstream(node)` | Recalcul ciblé, propagation des périmés | bannières "Re-run", "Update" |
| `vf_job_start(kind, json)`, `vf_job_poll`, `vf_job_cancel`, `vf_job_result` | File unique de longs calculs (génération, entraînement, lot de vols, FEA, export), avec progression ; threads côté Rust | file de tâches |
| `vf_train_start` (via `vf_job_*`) sur `sim::train::tune_gains` / `train_policy` | Entraînement PID + politique, courbes et épisodes en flux | Training |
| `vf_fea_run` (via `vf_job_*`) | Contrainte sur la frame pour les cas de charge issus du vol | Simulation, Generative |
| `vf_probe(domain, id)` | Correspondance composant PCB et pièce 3D, sélection liée entre ateliers | Electronics, Mechanics |
| `vf_export(kind, json)` | STEP, DXF, 3MF, Gerber, KiCad, BOM, ONNX de la politique | Manufacture |
| `vf_asm_*` (joints, mouvement, masse et inertie) | Atelier Mechanics, source de la masse envoyée à la simulation | Mechanics |
| existants : `sc_*`, `pcb_*`, `vf_link_push/mount/revision`, `sc_generate_study/sc_generate`, `vf_sim_*` | restent tels quels | |

Le rendu photoréaliste reste en Swift (Metal) : le cœur Rust fournit la scène (`sc_scene_*`), pas de moteur de rendu dans le Rust.

## 4. Feuille de route

**Phase 0 : simulation en Rust (en cours par une autre session).** Constaté le 2026-11-04 : `SimEngine.swift` appelle déjà `vf_sim_*` (`bridge/include/viaform_sim.h`, `bridge/src/sim.rs`, crate `sim/` avec physique, contrôle, météo, course, planificateur, entraînement), `viaform-sim.js` n'est plus dans `apple/Resources`. Reste à faire : exposer l'entraînement (`vf_train_*` ou `vf_job_*`), tests de parité contre `electron/src/shared/sim/*.ts` (même graine, mêmes trajectoires à tolérance près), porter `generative.ts` s'il porte encore de la logique absente de `generative/`, puis supprimer `electron/` du dépôt.

**Phase 1 : chrome et graphe de projet (2 à 3 semaines).**
- Rust : `vf_project_*` (graphe, états, propagation), `vf_job_*` (file, progression, annulation).
- Swift : `apple/Shared/Model/ProjectModel.swift` (nouveau, @Observable sur le graphe), `apple/Desk/ProjectWindow.swift` (nouveau, remplace la racine de `DeskRootView.swift`), `PipelineBar.swift`, `BrowserTree.swift`, `InspectorView.swift`, `JobQueueView.swift`. `DeskRootView.swift` garde le ruban, extrait en `StageRibbon.swift`. Enum `Workspace` passe de 4 à 8 cas.

**Phase 2 : ateliers existants branchés au flux (2 semaines).** Design (`Viewport`, `ViewCube`, timeline), Generative (`GenerateView`, grille de variantes, "Use in Design" crée la révision et marque l'aval périmé), Electronics (`DeskPCBView`, `PCBCanvas`, `vf_link_*`, panneau ancré 3D), Simulation (`SimulationView`, bannière "Re-run on v12").

**Phase 3 : nouveaux ateliers (3 à 4 semaines).** Mechanics (`vf_asm_*`, joints, étude de mouvement, masse vers la simulation), Training (`vf_train_*`, courbes `Swift Charts`, liste d'épisodes, rejouer dans la simulation, panneau ancré), Render (Metal, file de rendu dans `vf_job_*` côté Swift), Manufacture (`vf_export`, contrôles, paquet de livraison).

**Phase 4 : finitions Mac.** Pilule contextuelle (B), popover graphe (E), palette `Cmd+K`, `Commands` complet, `DocumentGroup` et fichier projet, réglages, tests d'interface sur 13 pouces et 27 pouces, accessibilité (VoiceOver sur l'arbre et la barre de pipeline).

Risques : le ruban personnalisé et la barre de pipeline dans la barre d'outils (prévoir le repli), le coût de deux vues Metal simultanées en mode ancré (partager le `MTLDevice` et limiter la fréquence de la vue secondaire), la propagation des périmés qui doit rester rapide (calcul incrémental dans le Rust, jamais un recalcul complet à chaque édition).
