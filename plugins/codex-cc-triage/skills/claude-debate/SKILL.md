---
name: claude-debate
description: Compare competing technical positions with Claude when the owner authorizes a bounded independent debate.
---

# Claude Debate

State the decision, constraints, alternatives and your initial position. Apply the [ownership and dispatch rules](../references/ownership.md). Use one distinct persistent task name and `claude-thread.sh dispatch plan "<thread>"` for the opening. Ask Claude for its strongest independent position and the evidence that would change it.

Challenge the material disagreement with `claude-thread.sh reply "<thread>"`. Each call is one round. Stop at five rounds including synthesis, fewer when the owner sets fewer. Finish early when the evidence settles the decision or a round adds no useful evidence. Use the existing exchange for a local synthesis at the limit.

Return where the positions agree, the strongest remaining disagreement and a recommendation with its deciding evidence. A debate produces advice. Approval of a candidate follows required review.
