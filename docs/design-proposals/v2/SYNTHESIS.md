# ViaForm v2 : synthèse des 4 directions d'interface

Deuxième tour après `../SYNTHESIS.md` (5 maquettes HTML, recommandation : pipeline C + chrome ruban A + menu flottant et inspecteur B). Ce tour pousse quatre directions jusqu'au concept image puis jusqu'à un prototype SwiftUI qui compile et rend ses écrans en PNG. Vitrine commune : main robotique humanoïde (doigts et articulations génératifs, un moteur par degré de liberté) et drone FPV 3 pouces (cadre génératif, PCB, vol simulé avec vent et parcours de portes).

Galerie côte à côte : [index.html](index.html). Aucun nom ni logo de produit tiers dans les images ni dans les textes d'interface. Les mots "Fusion" et "Shapr" ci-dessous désignent les références, jamais l'UI.

## 1. Les quatre directions

### Pro Ribbon (`fusion-faithful/`)
Clone de structure de la référence desktop, en clair : barre d'app (grille de données, enregistrer, annuler, onglet de document, Jobs, cloche, avatar), sélecteur d'atelier encadré, rangée d'onglets en capitales, ruban à grosses icônes jet en panneaux avec légende et chevron, bouton de validation vert à droite, BROWSER flottant à oeil, dialogue de commande à droite (REVOLUTE JOINT, Cancel / OK), badge de valeur sur le gizmo, cube de vue avec maison, barre de navigation en bas au centre, trièdre, timeline paramétrique avec lecture et tête de lecture. iPad : capsule haute, colonne d'outils légendée, pilule contextuelle, bulle 35 deg avec arc pointillé, carte ITEMS, capsule History. Prototype `ProRibbon`, barre d'app dessinée à la main (pas de barre d'outils NSWindow).

- Concepts : [1-design](fusion-faithful/concepts/1-design.png), [2-generative](fusion-faithful/concepts/2-generative.png), [3-simulation](fusion-faithful/concepts/3-simulation.png), [4-electronics](fusion-faithful/concepts/4-electronics.png), [5-ipad-hand](fusion-faithful/concepts/5-ipad-hand.png)
- SwiftUI : [1-design](fusion-faithful/swiftui/screens/1-design.png), [2-generative](fusion-faithful/swiftui/screens/2-generative.png), [3-simulation](fusion-faithful/swiftui/screens/3-simulation.png), [4-electronics](fusion-faithful/swiftui/screens/4-electronics.png), [5-ipad-hand](fusion-faithful/swiftui/screens/5-ipad-hand.png)

### Hybrid Pipeline (`hybrid-pipeline/`)
Suite directe de la recommandation v1, en sombre : PipelineBar des 8 ateliers dans la barre d'outils (puces chaînées, pastille d'état ou spinner), ruban groupé à légendes en capitales, arbre BROWSER à gauche avec PIPELINE OUTPUTS épinglé, inspecteur docké à droite (bloc FLOW consomme / produit, LINKED SELECTION), cube, trièdre, pilule de navigation, timeline icônes numérotées, barre d'état dense. Simulation : trois tracés alignés sur une tête de lecture commune. iPad : rail 44 pt, carte inspecteur 320 pt avec curseur, pilule contextuelle, bande pipeline icônes seules. Seule direction bâtie sur les conteneurs système (NavigationSplitView, `.inspector`, `.toolbar` principal, `.unified`, Cmd+1..8).

- Concepts : [1-design](hybrid-pipeline/concepts/1-design.png), [2-generative](hybrid-pipeline/concepts/2-generative.png), [3-simulation](hybrid-pipeline/concepts/3-simulation.png), [4-electronics](hybrid-pipeline/concepts/4-electronics.png), [5-ipad](hybrid-pipeline/concepts/5-ipad.png)
- SwiftUI : [1-design](hybrid-pipeline/swiftui/screens/1-design.png), [2-generative](hybrid-pipeline/swiftui/screens/2-generative.png), [3-simulation](hybrid-pipeline/swiftui/screens/3-simulation.png), [4-electronics](hybrid-pipeline/swiftui/screens/4-electronics.png), [5-ipad](hybrid-pipeline/swiftui/screens/5-ipad.png)

### Direct Canvas (`shapr-direct/`)
Clone de structure de la référence tactile, sur Mac comme sur iPad : viewport clair plein cadre, carte titre flottante avec segments d'atelier, rail d'outils fin, capsule contextuelle au dessus de la sélection avec pas à pas de valeur, carte Items | History, carte de propriétés, palette Cmd+K avec raccourcis à une touche (E, F, M, J). iPad : groupes d'outils esquisse et solide séparés, bulle bleue sur la poignée de face, barre adaptative. PCB, scène de vol, portes et graphes dessinés nativement, pas de recadrage.

- Concepts : [1-design](shapr-direct/concepts/1-design.png), [2-generative](shapr-direct/concepts/2-generative.png), [3-simulation](shapr-direct/concepts/3-simulation.png), [4-electronics](shapr-direct/concepts/4-electronics.png), [5-ipad](shapr-direct/concepts/5-ipad.png)
- SwiftUI : [1-design](shapr-direct/swiftui/screens/1-design.png), [2-generative](shapr-direct/swiftui/screens/2-generative.png), [3-simulation](shapr-direct/swiftui/screens/3-simulation.png), [4-electronics](shapr-direct/swiftui/screens/4-electronics.png), [5-ipad](shapr-direct/swiftui/screens/5-ipad.png), [6-command-search](shapr-direct/swiftui/screens/6-command-search.png)

### Liquid Glass Studio (`liquid-studio/`)
Panneaux de verre flottants sur un viewport plein cadre, une couleur d'accent par atelier (bleu, rose, sarcelle, orange), un seul document "Racer 3in" et une seule révision "Frame v8" partout. Ruban seulement en Design. Simulation la plus spectaculaire (parcours au couchant, HUD chiffré, barres moteurs, "Re-run on Frame v8"), PCB Canvas le plus dense, panneau d'étude générative le plus complet. Verre simulé dans les PNG, vrai `.glassEffect` prévu sur macOS 26, plaques 3D raster générées.

- Concepts : [1-design](liquid-studio/concepts/1-design.png), [2-generative](liquid-studio/concepts/2-generative.png), [3-simulation](liquid-studio/concepts/3-simulation.png), [4-electronics](liquid-studio/concepts/4-electronics.png), [5-ipad-hand](liquid-studio/concepts/5-ipad-hand.png)
- SwiftUI : [1-design](liquid-studio/swiftui/screens/1-design.png), [2-generative](liquid-studio/swiftui/screens/2-generative.png), [3-simulation](liquid-studio/swiftui/screens/3-simulation.png), [4-electronics](liquid-studio/swiftui/screens/4-electronics.png), [5-ipad-hand](liquid-studio/swiftui/screens/5-ipad-hand.png)

Points communs à toutes : les zones 3D sont des images (recadrées ou générées), pas du Metal ; Mechanics, Training, Render et Manufacture n'ont pas d'écran propre ; la main s'arrête après Design ; les vues iPad sont des vues macOS rendues à la taille iPad.

## 2. Notes des trois juges

Sur 10. Ressemblance = un utilisateur de la référence desktop se sent chez lui sur Mac, celui de la référence tactile sur iPad. Flux = les 8 ateliers se lisent comme un seul produit (lignée, périmés, sélection liée, tâches longues). Faisabilité = fidélité du SwiftUI au concept, adéquation HIG, coût d'intégration dans `apple/`, tenue sur 13 pouces.

| Direction | Ressemblance | Flux | Faisabilité | Total /30 |
|---|---|---|---|---|
| Hybrid Pipeline | 7 | 7,5 | 8 | **22,5** |
| Pro Ribbon | 8,5 | 3 | 7 | 18,5 |
| Direct Canvas | 6 | 4 | 7 | 17 |
| Liquid Glass Studio | 5 | 5,5 | 6,5 | 17 |

Lecture : Pro Ribbon gagne la ressemblance de loin mais cache le pipeline (menu déroulant, documents séparés, timeline CAO hors sujet hors Design). Hybrid est deuxième partout sauf en flux et en faisabilité où il est premier ; c'est le seul au dessus de 7 sur les trois axes.

## 3. Recommandation : Hybrid Pipeline, habillé du chrome Pro Ribbon

Base : la structure Hybrid (conteneurs système, PipelineBar, BROWSER + PIPELINE OUTPUTS, inspecteur, barre d'état, ateliers en types valeur). Greffes, par ordre de priorité :

1. **Chrome Pro Ribbon (ressemblance).** Thème clair par défaut avec viewport dégradé gris clair, thème sombre Hybrid (`#1C1E22`) en variante, les deux suivant l'apparence système. Ruban à grosses icônes jet en Design (42 pt, légendes en capitales, chevron de groupe), boutons légendés denses en ateliers secondaires (Wind, Rain, Track, Via, DRC, ERC). Dialogue de commande transitoire à droite (Composant 1 / 2, Mouvement, Axe, Limites, Moteur, Cancel / OK) à la place de l'inspecteur permanent pendant une commande. Badge de valeur sur le gizmo et arc de rotation (Liquid). Cube avec bouton maison, barre de navigation en bas au centre.
2. **Hygiène juridique.** Onglets renommés (par exemple BODY / FREEFORM / FACETS / FOLD / MOLD / TOOLS), bouton de validation restylé (pas de rond vert coché : bouton accent "Done" avec raccourci Retour), "Press Pull" renommé "Push / Pull" ou "Offset Face", jamais "ViewCube" dans l'UI, famille d'icônes jet conservée. Icônes jet sur pastille claire en thème sombre (contraste trop faible aujourd'hui).
3. **Pipeline sans triple langage (flux).** La PipelineBar porte seule l'état d'étape ; repli ViewThatFits vers un menu déroulant d'atelier façon référence, chaque ligne avec sa pastille (rendu à 1440 pt obligatoire). LINKED SELECTION réduit à une ligne de présence sans pastille, repliée par défaut. PIPELINE OUTPUTS garde l'état et ajoute une raison et une action par ligne ("Assembly stale : Frame v12 replaced v11 . Update"). Popover Update rendu et testé.
4. **Un document, une révision (Liquid).** Un projet par produit ("Racer 3in", "Humanoid Hand"), révisions nommées "Frame v12", "Board rev C", "Policy v5" partout. Carte scénario listant les entrées amont (Airframe Frame v12 153 g, Controller PID + Policy v5). Capsule de tâche avec verbe et ETA ("Generating 74 of 120 . 3 min left", pause) à la place de la barre d'état contradictoire. "Re-run on Frame vN" en action principale dès qu'une étape est périmée. Accent par atelier limité à la puce active de la PipelineBar ; boutons principaux en accent unique.
5. **Verbes inter ateliers et palette (Direct Canvas).** Pilule contextuelle avec Use as Frame, Stress here (ouvre Generative avec le cas de charge du crash), Show in 3D, Re-run. Palette Cmd+K sur les commandes des 8 ateliers avec raccourcis à une touche ; c'est aussi le secours du ruban replié sur 13 pouces. Bande horizontale de variantes sous le viewport Generative sur petits écrans.
6. **Timeline par atelier.** Timeline de fonctions uniquement en Design (rail connecté fait / à venir, Liquid) ; Generative = galerie de résultats, Simulation et Training = télémétrie Swift Charts à tête de lecture partagée (Roll / Pitch / Yaw, RPM, Battery, valeurs vives à côté), Electronics = rail à points avec mini icônes teintées et légende (concept Pro Ribbon).
7. **Contenus natifs.** PCB Canvas dense de Liquid (pastilles, passifs, fan-out, chevelu pointillé), inspecteur U1 avec Route / Show in 3D, capsule "DRC passed . 4 layers . 36 x 36 mm . 112 nets", carte lien 3D avec badge Live, cote de dégagement et ligne de rappel vers l'ancre réelle (Pro Ribbon). HUD de vol chiffré de Liquid. Panneau d'étude Liquid (Preserve, Obstacles, Load cases, Objectives, Material, Manufacturing) pour combler le bloc OBJECTIVES absent. Bouton vert "Parametric" renommé.
8. **iPad (Direct Canvas + Pro Ribbon).** Groupes d'outils esquisse et solide séparés et légendés, bascule Items | History dans la barre haute, oeil + cadenas par ligne, barre contextuelle adaptative sous la sélection (jamais sur les doigts), bulle de valeur avec arc pointillé, capsule résumé en bas (assemblage, articulations, moteurs, Liquid), cube dans la rangée haute. Pilule d'atelier limitée à 5 ateliers visibles + menu "Plus".
9. **Histoire complète.** Écrans Mechanics, Training, Render, Manufacture, et la main portée à travers tous : moteur par DDL en Mechanics, câblage tendons et moteurs en Electronics, saisie simulée, politique entraînée, paquet d'impression.

## 4. Hiérarchie SwiftUI cible

### apple/Desk (macOS 14+)

```
ViaFormApp
  DocumentGroup(ProjectDocument) ou WindowGroup > ProjectWindow
    @State ProjectModel (@Observable, miroir de vf_project_*), JobQueue, Selection, workspace
    .toolbarStyle(.unified)
    .toolbar
      .navigation   ProjectTitle (révision active), Undo / Redo
      .principal    PipelineBar = ViewThatFits {
                      chips légendés | icônes + puce active légendée | icônes | WorkspaceMenu (lignes à pastille, Cmd+1..8)
                    }  StageChip(icon, label, StatusDot | ProgressView) .popover(UpdatePopover(raison, Update))
      .primaryAction CommandSearchField (Cmd+K), JobsButton(badge, .popover JobQueueView), Share, InspectorToggle
    NavigationSplitView(columnVisibility)
      sidebar  BrowserPanel  (List + OutlineGroup de BrowserRow : disclosure, icône de type, oeil)
               PipelineOutputs (OutputRow : état, raison, action)         largeur 230 à 280
      detail   VStack(spacing 0)
                 StageRibbon(workspace.ribbon)  en .safeAreaInset(.top)
                   RibbonTabs (noms propres) > PanelStrip ViewThatFits(row n, n-1, ..., MorePanel)
                   RibbonGroup(ToolIcon jet | SF Symbol, légende capitales, Menu chevron) + DoneButton
                 ZStack  StageViewport(workspace)   MetalViewport | PCBCanvas | FlightScene
                   ViewCube + HomeButton (topTrailing), Triad (bottomLeading), NavPill (bottom, .ultraThinMaterial)
                   ContextPill + ValueBadge + GizmoArc   placés par AnchorLayout(vf_view_project)
                   CommandDialog (trailing, pendant une commande)
                   OverlayCards : FlightHUD, ScenarioCard, WindCompass, StressLegend, LoadLabels, LinkCard(leader)
                   JobCapsule (verbe, ETA, pause)
                 BottomPanel (repliable, par atelier)
                   Design FeatureTimeline (rail fait / à venir, tête de lecture qui recule)
                   Generative OutcomesGallery | VariantsStrip (13 pouces) + TradeOffChart
                   Simulation, Training TelemetryPanel (Swift Charts, tête partagée, valeurs vives)
                   Electronics LayerBar + DotRailTimeline
                 StatusBar (sélection, unités, zoom, état du coeur)
    .inspector(isPresented)  InspectorPanel
      SelectionCard, FlowRows (consomme / produit), LinkedPresence (une ligne, repliée)
      sections d'atelier : JointInspector | StudySetup (Objectives...) | ComponentInspector | ScenarioPanel
      KVRow, CheckRow, TradeOffChart
    CommandPalette (overlay Cmd+K, commandes des 8 ateliers, touches E F M J)
    .commands { CommandMenu("Workspace") Cmd+1..8, Toggle Sidebar / Inspector, Cmd+K }
```

Chaque atelier est un type valeur `StageScreen` (ribbon, primaryActions, browserRows, outputs, inspector, viewport, bottomPanel) fabriqué depuis le modèle. Réutilisation : `DeskRootView.Ribbon / RibbonPanel` deviennent `StageRibbon`, `BrowserPanel` reste, `CommandDialog`, `NavigationBar`, `TimelineBar` restent et sont restylés, `DeskPanels.MarkingMenu` sert de menu clic droit, `ToolboxSearch` devient `CommandPalette`, `DataPanel` reste derrière le bouton grille, `AppBar` disparaît au profit de `.toolbar`, `DeskPCBView` garde son canvas sous le style PCB dense. Tokens et feuilles partagées dans `apple/Shared/UI`.

### apple/Touch (iPadOS)

```
TouchRootView > ZStack
  StageViewport (1 doigt orbite, 2 doigts pan, pincer zoom, tap 2 doigts annule, Pencil sélection / esquisse)
  AnchorLayout  ContextPill(.tall, 60 pt) sous la sélection, FaceHandle + ValueBubble + arc pointillé
  VStack
    TopCapsule  menu, titre + révision, Undo / Redo, TouchPipelineStrip (5 visibles + Plus, puce active légendée,
                pastilles), Items | History, ViewCube, Jobs, Share
    HStack  PadToolGroup x2 (esquisse, solide ; 44 pt mini, légendes) | Spacer | TouchInspectorCard 320 pt (Slider vif, Done)
    SummaryCapsule (assemblage, articulations, moteurs) ou TransportBar en Simulation / Training
  .sheet  BrowserPanel (lignes 48 pt, oeil + cadenas), ExportSheet, CommandPalette
```

Correspondances : `ToolRail` > `PadToolGroup`, `SuggestionBar` > `ContextPill(.tall)`, `ItemsPanel` / `HistorySidebar` > cartes basculées, `HistoryBar` > timeline flottante Design, `ProjectSidebar` > sheet, `CommandBrowser` > `CommandPalette`, enum `Space` > `Workspace` 8 cas. Toutes les cibles 44 pt ou plus.

## 5. Fonctions bridge/ à ajouter

Existant : `sc_session_new`, `sc_commands`, `pcb_session_new`, `pcb_commands`, `vf_bom_new`, `vf_sim_*` (catalog, parts, airframe, vehicle, world, pilot, start, advance, disturb, episode, free), `vf_train_start / progress / cancel / free`.

À ajouter (ABI C, JSON en sortie comme l'existant, un en-tête par domaine) :

| Domaine | Fonctions | Sert à |
|---|---|---|
| Projet | `vf_project_new / open / save / free`, `vf_project_stages` (8 étapes, état, raison), `vf_project_outputs`, `vf_project_update(stage)`, `vf_project_subscribe(cb)` | PipelineBar, PIPELINE OUTPUTS, popover Update, propagation incrémentale des périmés |
| Révisions | `vf_rev_list(artifact)`, `vf_rev_promote(outcome)` ("Use as Frame"), `vf_rev_diff` | nom unique "Frame v12", raisons des périmés |
| Arbre | `vf_project_tree(stage)`, `vf_tree_set_visible / set_locked` | BrowserPanel multi domaines, oeil + cadenas |
| Sélection | `vf_select_set / get`, `vf_select_linked` (présence par atelier), `vf_select_anchor` (point 3D d'ancrage) | LinkedPresence, ContextPill, leader de la carte lien |
| Vue | `vf_view_project(anchor, camera)` (ou côté Swift sur la caméra Metal) | AnchorLayout |
| Commandes | `vf_commands_all` (8 ateliers, raccourci, groupe), `vf_cmd_search(q)`, `vf_cmd_begin / set_param / preview / commit / cancel` | CommandPalette, CommandDialog, ruban, raccourcis E F M J |
| Tâches | `vf_job_list`, `vf_job_progress(id)` (verbe, n / total, ETA), `vf_job_pause / resume / cancel` ; `vf_train_*` et les études s'y inscrivent | JobsButton, JobCapsule |
| Génératif | `vf_gen_study_new / set (preserve, obstacles, loads, objectives, material, process) / run`, `vf_gen_outcomes`, `vf_gen_load_from_crash(run, t)` ("Stress here") | StudySetup, OutcomesGallery, TradeOffChart |
| Mécanique | `vf_asm_joints`, `vf_asm_set_joint(limits, motor)`, `vf_asm_motion_study`, `vf_asm_mass_props` | JointInspector, masse vers la simulation |
| Électronique | `vf_link_keepin(frame_rev)`, `vf_link_board_pose`, `vf_pcb_drc_summary` | carte lien 3D, cote de dégagement, capsule DRC |
| Simulation | `vf_sim_telemetry(run, channels, decimate)`, `vf_sim_scenario_inputs(run)` | TelemetryPanel, carte scénario (révisions amont) |
| Fabrication / rendu | `vf_export(kind, rev)`, `vf_mfg_checks`, `vf_render_enqueue` | Manufacture, Render |

## 6. Plan de mise en oeuvre

Ordonné pour tourner pendant que d'autres agents finissent `generative/` et `sim/` : les étapes 1 à 5 ne touchent ni ces crates ni leurs fichiers bridge, et tout passe par un protocole Swift avec implémentation factice d'abord.

1. **Tokens et thèmes** dans `apple/Shared/UI` : palette claire (viewport gris dégradé) et sombre `#1C1E22`, accent unique + accents de puce par atelier, typographie, icônes jet + variante sur pastille claire. Test de contraste. Aucune dépendance.
2. **Modèle Swift factice** : `apple/Shared/Model/ProjectModel.swift` (@Observable), `Workspace` 8 cas, `StageScreen`, `ProjectService` protocole avec `MockProjectService` (données Racer 3in et Humanoid Hand, révisions "Frame v12", "Board rev C", "Policy v5").
3. **Squelette Desk** : `apple/Desk/ProjectWindow.swift` (NavigationSplitView, `.toolbar`, `.inspector`, Cmd+1..8), `PipelineBar.swift` avec ses 4 replis et `UpdatePopover`, `JobsButton`, `StatusBar`. `DeskRootView` reste branché en parallèle derrière un réglage jusqu'à l'étape 8. Captures 1440 x 900 et 2560 x 1440 dans les deux thèmes.
4. **Ruban et dialogue** : extraire `StageRibbon.swift` de `DeskRootView.Ribbon`, onglets renommés, `DoneButton`, `MorePanel`, `CommandDialog` transitoire, `CommandPalette` depuis `ToolboxSearch`. Lecture des commandes via `sc_commands` / `pcb_commands` déjà présents.
5. **Bridge projet, sélection, commandes, tâches** dans de nouveaux fichiers `bridge/src/project.rs`, `select.rs`, `commands.rs`, `jobs.rs` et leurs en-têtes ; `core/` porte le graphe et la propagation incrémentale. `ProjectService` réel remplace le factice. Ne touche ni `sim.rs` ni `generative/`.
6. **Design et Electronics branchés** : Viewport Metal, AnchorLayout, ContextPill, ValueBadge + GizmoArc, FeatureTimeline ; PCB dense, carte lien avec leader et cote (`vf_link_*`), capsule DRC, DotRailTimeline.
7. **Touch** : `TouchRootView` réorganisé selon la section 4 en réutilisant les feuilles partagées ; essais sur simulateur iPad (un simulateur dédié).
8. **Après livraison de `generative/` et `sim/`** : `vf_gen_*`, `vf_sim_telemetry`, `vf_sim_scenario_inputs`, inscription de `vf_train_*` et des études dans `vf_job_*` ; écrans Generative (StudySetup, galerie, variantes, Use as Frame), Simulation (HUD, télémétrie, Re-run on Frame vN, Stress here vers Generative). Retrait de l'ancienne racine `DeskRootView`.
9. **Nouveaux ateliers** : Mechanics (`vf_asm_*`), Training (courbes, épisodes, rejouer en simulation), Render (file Metal), Manufacture (`vf_export`, contrôles, paquet). Main portée à travers les 8.
10. **Finitions** : relecture juridique des libellés et glyphes, VoiceOver sur l'arbre et la PipelineBar, tests UI 13 et 27 pouces, `DocumentGroup` et format de fichier projet.

Risques : PipelineBar et ruban sur 13 pouces (replis à rendre dès l'étape 3), deux vues Metal en mode lien (partager le `MTLDevice`, limiter la fréquence de la vue secondaire), propagation des périmés qui doit rester incrémentale côté Rust, ressemblance de trade dress (étape 10 bloquante avant toute diffusion).
