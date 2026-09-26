# Prior Assistive Tech for Autistic Social Interaction (wearables, AR, real-time aids) — what worked vs. failed

Scope note: research done 2026-09-26 with ~17 search/fetch calls. Items marked "(background, not verified this session)" come from prior knowledge and had no source fetched; the report writer should treat them as leads, not facts.

## 1. Stanford Superpower Glass (Google Glass emotion cues for kids; Voss, Wall et al., JAMA Pediatrics 2019)

### Takeaway
The only randomized trial of a glasses-based social aid found a small gain on one parent-rated social score (about 4.6 points on the Vineland socialization scale) that faded 6 weeks after stopping. It found no gain on emotion-recognition tests, had ~49% dropout, and parents knew which group their child was in. It is weak evidence that the glasses "trained" social skill, and no evidence of real-time in-conversation help.

### Cited Findings
- Design: RCT, 71 children aged 6–12 with an autism diagnosis; 40 got Superpower Glass + usual ABA therapy, 31 got ABA only; 6-week intervention + 6-week follow-up; 52 "completers" — [JAMA Pediatrics](https://jamanetwork.com/journals/jamapediatrics/fullarticle/2728462); [PubMed](https://pubmed.ncbi.nlm.nih.gov/30907929)
- How it worked: child wears Google Glass linked to a phone app; the app detects faces/expressions and gives cues to encourage looking at faces and naming emotions (used mostly in structured at-home games, not live conversations) — [PubMed](https://pubmed.ncbi.nlm.nih.gov/30907929); [Superpower Glass systems paper, arXiv](https://arxiv.org/pdf/2002.06581)
- Primary result (intent-to-treat): Vineland-II socialization subscale, mean treatment effect 4.58 points (SE 1.62), P = .005; completers only: 5.38 points, P < .001 — [JAMA Pediatrics](https://jamanetwork.com/journals/jamapediatrics/fullarticle/2728462)
- Authors state 4.58 points is "comparable with gains observed with standard of care therapy" — [PubMed](https://pubmed.ncbi.nlm.nih.gov/30907929)
- Secondary outcomes: Emotion Guessing Game P = .05 (borderline); Social Responsiveness Scale-II no difference (P = .26); NEPSY-II Affect Recognition no change (P = .86) — [JAMA Pediatrics](https://jamanetwork.com/journals/jamapediatrics/fullarticle/2728462)
- At 12-week follow-up, the Vineland gain was no longer significant (P = .26) — [JAMA Pediatrics](https://jamanetwork.com/journals/jamapediatrics/fullarticle/2728462)
- Critiques (Spectrum/The Transmitter, 2 May 2019): parents were not blinded and could rate kids better just from seeing the glasses (Rebecca Jones, Weill Cornell); no sham control (Jonathan Green, Manchester, who called it "basically science's use as a marketing exercise"); "not a slam dunk" (James Rehg, Georgia Tech); 35 of 71 dropped out (19 during treatment, 16 during follow-up); kids used it about half the recommended time; no gain on two emotion-recognition tests — [The Transmitter](https://www.thetransmitter.org/spectrum/tech-firms-superpower-glass-autism-not-super-experts-say/)
- Earlier at-home feasibility study: parents reported more eye contact, but children's interest steadily declined over the study — [PMC6550272 / summarized via search](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6550272/)
- Commercial path: Cognoa exclusively licensed Superpower Glass (2019) and got FDA Breakthrough Device designation for it — [Wearable Technologies](https://www.wearable-technologies.com/2019/04/cognoa-licenses-google-glass-based-ai-technology-for-children-with-autism/)

### Inferences
- The benefit, if real, looks like a practice/training effect in structured games, not a live-conversation aid. It says little about adults using a copilot during real talks.
- Novelty wear-off (falling interest, half-dose use, high dropout) is the clearest lesson: glasses-based aids lose users fast.
- The one "positive" outcome was parent-reported with parents unblinded; the objective emotion tests did not move.

### Gaps
- Could not confirm whether Cognoa ever brought a Glass-based product to market (Cognoa's FDA-cleared product, Canvas Dx, is a diagnostic app, not Glass) (background, not verified this session).
- No adult or long-term (>3 month) data found.

## 2. Brain Power / Empowered Brain (Google Glass, Ned Sahin)

### Takeaway
Small, uncontrolled or lightly controlled studies, mostly run and funded by the company, reported that the glasses were tolerated and linked to better teacher/parent ratings. No independent RCT found; product appears to have faded with Google Glass.

### Cited Findings
- Safety study: 18 children and adults with autism; 89% could wear and use the device, 87.5% reported no negative effects; minor effects temporary — [PMC6111791](https://pmc.ncbi.nlm.nih.gov/articles/PMC6111791/)
- School study ("multi-stage feasibility and controlled efficacy"): reported gains in social withdrawal, irritability, hyperactivity on the Aberrant Behavior Checklist and SRS-2; 8 children all found it useful and not overwhelming — [Behavioral Sciences 2018](https://doi.org/10.3390/bs8100085); [Brain Power research page](https://brain-power.com/empowered-brain/research/)
- Company framed results as helping ADHD symptoms in autistic people (company Medium post) — [Empowerment Lab Medium](https://medium.com/@EmpowermentLab/new-research-finds-augmented-reality-google-glass-can-help-adhd-symptoms-in-people-with-autism-e3af7e2d2d25)
- Crowdfunding campaign billed as "World's First Augmented Reality Glasses for Autism" — [Indiegogo](https://www.indiegogo.com/en/projects/nedsahin/world-s-first-augmented-reality-glasses-for-autism)

### Inferences
- Evidence quality is low: tiny samples, company-authored, rating scales filled by people who know the child used the device. Treat "efficacy" claims as marketing-grade.
- Tolerability (most people can wear glasses without sensory distress) is the most solid finding and is useful for a copilot.

### Gaps
- Could not verify current company status (no recent product news found); likely dormant after Google Glass consumer/enterprise sunset (background, not verified).

## 3. Emotion AI: MIT emotional social-intelligence prosthesis, Affectiva, and the science critique

### Takeaway
The idea of reading emotions from faces is scientifically contested. The major 2019 review found facial movements do not reliably map to emotions across people and contexts, and Microsoft pulled its emotion-detection API in 2022 for this reason. A copilot that tells users "they are angry" from faces rests on a shaky base.

### Cited Findings
- Barrett, Adolphs, Marsella, Martinez, Pollak (2019, Psychological Science in the Public Interest): challenge the assumption that emotional states "can be readily inferred" from facial movements; stress large cultural, individual and context variation — [SAGE](https://journals.sagepub.com/doi/10.1177/1529100619832930); [APS summary](https://www.psychologicalscience.org/publications/emotional-expressions-reconsidered-challenges-to-inferring-emotion-from-human-facial-movements.html)
- Microsoft retired emotion inference from Azure Face: no new customers from 21 June 2022, existing customers cut off 30 June 2023, citing lack of consensus on defining "emotions," overgeneralization, and risk of stereotyping/discrimination — [Azure blog](https://azure.microsoft.com/en-us/blog/responsible-ai-investments-and-safeguards-for-facial-recognition/); [Gizmodo](https://gizmodo.com/microsoft-shutting-down-azure-facial-emotion-recognitio-1849090511)
- Cambridge Autism Research Centre (Baron-Cohen) + Emteq Labs smart-glasses project: testing whether AI can read mental states in real time to support autistic people; still in design/focus-group stage, results expected October 2028; involves autistic community consultation — [Autism Research Centre](https://www.autismresearchcentre.com/projects/smart-glasses/)

### Inferences
- Autistic users already report misreading faces; a tool that confidently mislabels emotions could make things worse. Prefer cues from words and tone the user can check, and show uncertainty.
- After 20 years (MIT prosthesis ~2005 → Cambridge 2028), no real-time emotion-reading wearable has shown real-world benefit in a solid trial.

### Gaps
- Not fetched this session: MIT Media Lab "emotional social intelligence prosthesis" (el Kaliouby & Picard, ~2005–2008) details; Affectiva's acquisition by Smart Eye (2021) and pivot to automotive; EU AI Act ban on emotion recognition in workplaces and schools (in force Feb 2025). All background, not verified this session.

## 4. Real-time captions / AR captions (XRAI Glass, Live Transcribe, TranscribeGlass, Meta Ray-Ban Display)

### Takeaway
Caption glasses are real, shipping products built for Deaf/hard-of-hearing users. For autistic people or people with auditory processing disorder (APD), I found only testimonials and marketing, no studies.

### Cited Findings
- XRAI Glass: app that turns speech into subtitles on smart glasses; iOS/Android — [XRAI Glass](https://xrai.glass/); [App Store](https://apps.apple.com/us/app/xrai-glass/id6447922836)
- XRAI marketing claims "countless people with cognitive auditory processing disorder" benefit; one user review says it helps a husband with APD plus partial hearing loss (anecdote) — [Pratt IXD review](https://ixd.prattsi.org/2023/09/assistive-technology-xrai-glass-app-glasses/); [Reviewed](https://www.reviewed.com/accessibility/features/xrai-glass-app-smart-subtitle-deaf-community)
- TranscribeGlass: captioning glasses for deaf/hard-of-hearing/elderly; founder Tom Pritsky (Stanford) says they fill gaps hearing aids leave — [ACM news](https://cacmb4.acm.org/news/277236-glasses-transcribe-speech-in-real-time)
- Meta Ray-Ban Display has live captions on the in-lens display, including captions on phone/WhatsApp/Messenger/Instagram calls — [Meta help](https://www.meta.com/help/ai-glasses/23879220601763496/); [Meta Newsroom May 2026](https://about.fb.com/news/2026/05/meta-ai-wearables-changing-the-game-for-disabled-people/amp/)

### Inferences
- Captions are the most mature, least controversial real-time glasses feature. For autistic users, captions could cut processing load in noisy rooms, but this is untested.

### Gaps
- No peer-reviewed study found of caption glasses with autistic or APD users. No latency/accuracy data for these products in noisy group talk found this session.

## 5. Social-skills apps, VR training, video modeling — does it generalize?

### Takeaway
Training tools show medium-to-large effects in the lab or on the trained task, but moving those skills into real life is the recurring weak point. Studies are small and outcome measures vary.

### Cited Findings
- Meta-analysis: 14 face-to-face social-skills programs (g = 0.81) vs 4 tech-based programs (g = 0.93), both medium-to-large — [J. Technology in Behavioral Science 2020](https://link.springer.com/article/10.1007/s41347-020-00177-0)
- 2025 meta-analysis of IT-based interventions: desktop video modeling beat mobile apps for emotion recognition; professional-delivered beat caregiver-delivered; some studies show "limited generalization or transient effects"; VR/AR job-skill studies rarely measured real employment outcomes — [PMC12387758](https://pmc.ncbi.nlm.nih.gov/articles/PMC12387758/)
- Floreo VR Joint Attention pilot: 12 participants aged 9–16, 14 sessions over 5 weeks; safe, well tolerated, more interactions/eye contact (no control group) — [JMIR Pediatrics 2019](https://pediatrics.jmir.org/2019/2/e14429/)
- Floreo "Building Social Connections" randomized feasibility study: 8 intervention vs 6 control, ~36 sessions over 12–15 weeks in ABA clinics, measured with Autism Impact Measure (preprint 2025) — [medRxiv](https://www.medrxiv.org/content/10.1101/2025.08.28.25334679v1.full)
- Video modeling is established for social-communication and functional skills in kids; ASHA tutorial (2024) extends it to autistic adults — [ASHA AJSLP](https://pubs.asha.org/doi/10.1044/2024_AJSLP-23-00479)
- Meta-analysis of immersive VR RCTs for autistic children/adolescents exists (2024) — [Research in Developmental Disabilities](https://www.sciencedirect.com/science/article/abs/pii/S0891422224001033)

### Inferences
- An in-the-moment copilot is partly a bet around the generalization problem: help at the point of need instead of hoping practiced skills transfer. But that also means benefits may vanish when the device is off (as with Superpower Glass).
- Company-run feasibility studies (Floreo) are typical; independent replication is rare.

### Gaps
- Social Compass evidence not searched. Effect sizes for the 2024 VR meta-analysis not fetched.

## 6. LLM assistants used by autistic adults, and 2024–2026 "social copilot" products

### Takeaway
Autistic adults already use ChatGPT to draft messages, decode tone, and rehearse, and in one study strongly preferred it to a human advisor. But experts flag bad advice and a built-in bias toward neurotypical norms. The one real-time glasses product found (Antwerp startup) is pre-evidence.

### Cited Findings
- Jang, Moharana, Carrington, Begel (CHI 2024), "It's the only thing I can trust": 11 autistic workers asked workplace social questions to a GPT-4 chatbot and a disguised human; they strongly preferred the LLM; a job coach judged some LLM advice questionable; risks include neurotypical bias — [ACM DL](https://dl.acm.org/doi/10.1145/3613904.3642894); [arXiv](https://arxiv.org/abs/2403.03297)
- CHI 2024 "Unlock Life with a Chat(GPT)": autistic participants given GPT-4 accounts used it for scheduling, clearer explanations, and communication practice — [ACM DL](https://dl.acm.org/doi/10.1145/3613904.3641989)
- CHI 2025 "As an Autistic Person Myself: The Bias Paradox Around Autism in LLMs": finds ChatGPT holds neurotypical social norms in its advice — [ACM DL](https://dl.acm.org/doi/full/10.1145/3706598.3713420)
- "Affordances and Risks of ChatGPT to Autistic Users" (Ma et al., Interactive Health '26, July 2026): empirical HCI study of benefits and risks; I could not extract sample size or specific findings — [arXiv](https://arxiv.org/pdf/2601.17946)
- Media coverage: people with autism turn to ChatGPT for workplace advice — [MedicalXpress June 2024](https://medicalxpress.com/news/2024-06-people-autism-chatgpt-advice-workplace.html)
- SocialWise (2026 arXiv): LLM-agent "conversation therapy" for autistic users (practice tool, not live) — [arXiv](https://arxiv.org/pdf/2604.15347)
- Antwerp startup (founder Mario Major, autistic + ADHD): smart glasses that read facial expressions and language in real time and show feedback on a discreet display, for autism/ADHD/dyslexia; planned €59/month subscription plus leasing and refurbished institutional units; no trial data reported — [Belga via search snippet](https://www.belganewsagency.eu/antwerp-start-up-builds-smart-glasses-to-help-neurodivergent-users-decode-social-cues) (page returned 404 on fetch; details from search snippet only)
- Remote-assistance smart glasses study with young adults with/without autism found usability promise but user discomfort — [Disability & Rehab: Assistive Tech 2025](https://www.tandfonline.com/doi/full/10.1080/17483107.2025.2494660)

### Inferences
- Demand signal is strong (users prefer LLM advice, feel it is non-judgmental), but it comes from asynchronous use (drafting, rehearsing), not live talk. Real-time use adds latency and attention costs not yet studied.
- Neurotypical bias is a design risk: a copilot that pushes "mask more" advice may conflict with what autistic users want.

### Gaps
- No peer-reviewed study found of a real-time LLM copilot (glasses or earpiece) used live by autistic people. The Antwerp startup's company name and launch status could not be confirmed.

## 7. Meta Ray-Ban / Ray-Ban Display accessibility use

### Takeaway
Meta's accessibility push is about blind/low-vision (Be My Eyes, scene description), mobility (voice, EMG band), and hearing (captions). Meta's own May 2026 accessibility post does not mention autistic, ADHD, or cognitive users at all, and gives no usage numbers.

### Cited Findings
- Be My Eyes on Ray-Ban Meta: voice command calls a sighted volunteer who sees through the glasses camera; expanded to trusted contacts and company support lines (Tesco, Amtrak, Hilton, etc.) — [Be My Eyes](https://www.bemyeyes.com/be-my-eyes-smartglasses/); [Be My Eyes news](https://www.bemyeyes.com/news/be-my-eyes-and-meta-launch-new-accessibility-functions/)
- Meta May 2026 post: user stories from a blind veteran (menus, airports), a quadriplegic veteran (voice capture), a spinal-cord-injury gamer (EMG); features include captioned calls on Display; no neurodivergent mention, no usage stats — [Meta Newsroom](https://about.fb.com/news/2026/05/meta-ai-wearables-changing-the-game-for-disabled-people/amp/)
- Meta accessibility hub for AI glasses — [Meta Store](https://www.meta.com/ai-glasses/accessibility/)

### Inferences
- Neurodivergent social support is an open gap in the biggest glasses platform — an opportunity, but also no evidence base to borrow.
- Mainstream-looking glasses (Ray-Ban) reduce the "medical device" look that hurt Google Glass-era tools.

### Gaps
- No independent study of Ray-Ban Meta use by disabled users found this session.

## 8. Common failure modes

### Takeaway
Across attempts, the failures are: novelty wear-off and dropout, weak/unblinded evidence, effects that vanish when the device is off, shaky emotion science, neurotypical-norm bias, and a deficit ("fix the autistic person") framing that autistic researchers reject.

### Cited Findings
- Dropout/engagement: Superpower Glass 49% dropout, half-dose use; interest declined in home study — [The Transmitter](https://www.thetransmitter.org/spectrum/tech-firms-superpower-glass-autism-not-super-experts-say/); [PMC6550272](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC6550272/)
- Effects not lasting after removal — [JAMA Pediatrics](https://jamanetwork.com/journals/jamapediatrics/fullarticle/2728462)
- Inaccuracy of emotion inference — [Barrett et al. 2019](https://journals.sagepub.com/doi/10.1177/1529100619832930); [Azure](https://azure.microsoft.com/en-us/blog/responsible-ai-investments-and-safeguards-for-facial-recognition/)
- Deficit framing: Williams & Gilbert (2020) argue much autism HCI research serves behaviorist "normalizing" goals; Spiel et al. (2022) note neurodivergent users treated as "problems to solve," even over participant resistance — [First Monday, "Not robots; Cyborgs"](https://firstmonday.org/ojs/index.php/fm/article/download/12910/10795/81727)
- Neurotypical bias in LLM advice — [CHI 2025](https://dl.acm.org/doi/full/10.1145/3706598.3713420); [CHI 2024](https://dl.acm.org/doi/10.1145/3613904.3642894)
- User discomfort with smart glasses among autistic young adults — [T&F 2025](https://www.tandfonline.com/doi/full/10.1080/17483107.2025.2494660)

### Inferences
- Lessons for a glasses copilot: (1) design for adults who choose it, not therapy imposed on kids; (2) avoid confident emotion labels from faces — ground cues in what was said and show uncertainty; (3) expect novelty drop-off and measure use at 1–3 months; (4) co-design with autistic users and let them set goals (not "look normal"); (5) run blinded or objective outcomes if claiming benefit; (6) plan for bystander consent/recording concerns.

### Gaps
- Not found/fetched: data on stigma of wearing a device in autistic adults specifically; cognitive-load/latency studies for in-conversation HUD prompts; bystander privacy studies for glasses (the Google Glass "Glasshole" backlash is background, not verified); general assistive-tech abandonment rates (Phillips & Zhao 1993 ~29% is background, not verified).
