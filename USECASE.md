# Myra Agents — Use Cases

> **But de ce fichier.** Contexte pour l'agent (toi, Claude). Avant de coder,
> concevoir, écrire de la copy ou trancher un arbitrage produit sur Myra, **relis-le
> et mets-toi à la place de l'utilisateur** : qui il est, quel job il essaie de
> faire, à quel moment il ouvre Myra. Une décision technique qui ignore le use case
> réel est une régression, même si le code est propre.
>
> Ce n'est **pas** une doc produit publique ni une liste de features. C'est la carte
> mentale des besoins que Myra sert, pour que chaque choix reste ancré dans l'usage.

---

## 1. Ce qu'est Myra (modèle mental)

Myra Agents = **plateforme desktop open-source de planification d'agents IA**
(app native macOS, Next.js 16 + Tauri, sidecar Rust). Positionnement de lancement :
« Open-Source desktop AI agent scheduler platform » — **pas** « un Kanban qui lance
des CLI ». Le Kanban est un moyen, pas la promesse.

La promesse : **automatise le boulot répétitif pendant que tu dors.** Tu décris une
tâche une fois, Myra fait tourner un agent (Claude Code, opencode, …) qui l'exécute
tout seul, à l'heure dite, sur ton Mac, avec accès à tes outils.

Le flux de valeur, toujours le même :

```
DÉCLENCHEUR  →  AGENT  →  OUTILS  →  SORTIE
(quand ?)       (qui ?)   (avec quoi ?) (quoi produit ?)

 time/cron      Claude Code   repo local     rapport Slack
 event (Slack)  opencode      Slack, Stripe  PR / commit
 manuel         CLI agent     GitHub, MCP    digest, fichier
```

Un use case Myra = **remplir ces 4 cases**. Quand tu conçois une feature, demande-toi
laquelle des 4 tu touches et ce que ça change pour l'utilisateur en bout de chaîne.

---

## 2. Les personas (dans l'ordre de réalité produit → vision)

| Persona | Ce qu'il veut | État produit aujourd'hui |
|---|---|---|
| **Développeur** | Déléguer bugs, PRs, tests, revue, sécu sur ses repos | **Cœur mûr** — ~75 % de l'inventaire de use cases |
| **Power user / ops** | Orchestrer des agents récurrents, workflows planifiés | Servi par le scheduler + triggers |
| **Solo-founder** | « Automatise mon business » : reporting, churn, FAQ, finance | Servi par ~6 use cases Data & Research |
| **Non-dev / grand public** | Automatisation ultra-simple, sans jargon | **Vision, pas encore réalité** — chantier produit |

> **Honnêteté brutale (à garder en tête).** L'inventaire actuel est massivement
> orienté dev/eng. La vision vise tout le monde (cf. mémoire `product-vision-non-dev`).
> Ne prétends jamais que Myra sert déjà bien le grand public : pour l'y amener, c'est
> un chantier **produit**, pas éditorial ni cosmétique. Quand tu proposes du travail,
> distingue « renforce le cœur dev » de « élargit vers le non-dev ».

---

## 3. Les jobs-to-be-done (le catalogue réel)

Ancré sur `automations.csv` + `usecases/`. Le **cœur** validé = **agents planifiés
(cron/schedules)** et **automatisations perso/répétitives**. Le reste gravite autour.

### 3.1 Cœur — agents planifiés & automatisations répétitives
La raison d'être. Une tâche chiante qui revient → un agent qui la fait seul, en boucle.
- **Résumé quotidien des changements** (`Summarize changes daily`) — digest eng des PRs/commits des dernières 24 h, posté sur Slack.
- **Slack Digest** (`Slack Digest Agent`) — roundup quotidien des messages qui demandent ton attention.
- **Product Finance / Stripe** (`Product Finance Agent`) — rapport récurrent revenus/churn/reco, read-only.
- **Product Analytics**, **Product FAQ**, **Customer health monitoring** — mêmes patterns récurrents côté solo-founder.

### 3.2 Code review & qualité
- Trouver les bugs critiques (`Find critical bugs`)
- Assigner les reviewers de PR (`Assign PR reviewers`)
- Ajouter de la couverture de test (`Add test coverage`)
- Surveiller des invariants d'ingénierie (`Monitor engineering invariants`)
- Générer de la doc (`Generate docs`)

### 3.3 Sécurité
- Scanner la codebase pour des vulnérabilités (`Scan codebase for vulnerabilities`)
- Trouver des vulnérabilités (`Find vulnerabilities`)
- Remédier aux vulnérabilités de dépendances (`Remediate dependency vulnerabilities`)

### 3.4 Incidents & triage
- Corriger les échecs de CI (`Fix CI failures`)
- Corriger les bugs remontés dans Slack (`Fix bugs reported in Slack`)
- Investiguer les incidents PagerDuty / issues Sentry / erreurs Datadog
- Trier les issues Linear (`Triage Linear issues`)

### 3.5 Data & research (le pont vers le non-dev)
Les seuls use cases **démontrables hors-dev** aujourd'hui (Stripe, Slack, analytics,
FAQ, churn, daily summary). Ils visent le solo-founder, pas encore le grand public.
C'est là que se joue l'élargissement de l'audience.

---

## 4. Anatomie d'un use case (le gabarit)

Chaque fichier `usecases/*` suit le même moule. Reconnais-le, respecte-le :

1. **Rôle** — « You are my Slack Attention Digest assistant. »
2. **Déclencheur** — `time` (cron) ou `event` (message Slack, webhook). Colonne `trigger` du CSV.
3. **Outils** — Slack, Stripe, GitHub, MCP… Colonne `tools`. L'agent n'a que ce qu'on lui câble.
4. **Scope / étapes** — instructions précises et bornées.
5. **Format de sortie** — sections Markdown fixes, envoi vers une destination définie.
6. **Garde-fous** — *systématiques* : `read-only`, `do not invent data`, `do not modify X`,
   ne rien envoyer d'autre que le rapport final. **La confiance = la feature.** Un agent
   autonome qui écrit sans garde-fou est un risque produit, pas une commodité.

Quand tu génères ou édites un use case, ces 6 blocs doivent tous être présents et cohérents.

---

## 5. Réflexe agent : se mettre à la place de l'utilisateur

Avant toute décision sur Myra, passe cette checklist :

- **Qui** ouvre cet écran / déclenche ce flux ? (dev ? solo-founder ? non-dev ?)
- **Quel job** essaie-t-il de finir ? (une des cases §3, ou un manque ?)
- **Quand / pourquoi** Myra tourne-t-il ? (planifié la nuit ? réaction à un event ? à la main ?)
- **Que voit-il en bout de chaîne** ? (un rapport ? une PR ? rien = échec silencieux ?)
- **Fait-il confiance au résultat** ? (garde-fous, honnêteté sur ce que l'agent a/n'a pas fait,
   pas de toast de succès non demandé — cf. mémoire `feedback_no-unrequested-toasts`).
- **Est-ce démontrable ?** Si le produit fait ce use case *mal*, ne le mets pas en avant.
   « On ne montre que ce que le produit prouve. »

Règle d'or, héritée de la ligne éditoriale : **le résultat est la star, l'outil est
figurant.** L'utilisateur ne veut pas « un agent avec MCP » ; il veut « mon reporting
s'écrit seul ». Optimise pour son résultat, pas pour la mécanique.

---

## 6. Ce que Myra n'est pas (anti-use-cases)

- Pas un IDE ni un copilote temps-réel — Myra est **asynchrone et autonome**, il tourne sans toi.
- Pas un no-code web type Zapier/Make — c'est une **app native qui pilote vraiment le Mac**
  (AX-driven), et c'est le moat. Un dashboard web qu'on clique n'est pas l'expérience visée.
- Pas un chatbot — on ne bavarde pas avec Myra, on lui **délègue** une tâche bornée qui se re-exécute.
