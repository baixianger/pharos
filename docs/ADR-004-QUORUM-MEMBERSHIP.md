# ADR-004: Quorum-certified membership transitions

- Status: Accepted for Pharos 2.0 production hardening
- Date: 2026-07-23
- Owners: Pai / Pharos

## Context

Pharos application data is local-first and converges through signed replica
events. Membership is different: it decides which keys may author those events
and which endpoints may issue RPCs.

The version-one transition is a complete next-epoch roster signed by one
controller. A replica accepts the first valid transition it sees and rejects a
different transition for the same next epoch. This fails closed on one replica,
but two disconnected replicas can accept conflicting proposals in opposite
orders and permanently disagree about the trusted roster.

A deterministic hash winner does not repair this safely. Events and commands
currently bind to a membership epoch, not a branch hash. Replacing an already
accepted same-epoch roster could retroactively authorize or reject operations
created on the losing branch.

Choosing one permanent controller as sequencer would avoid the fork but would
turn membership availability into the availability of one privileged device.
That conflicts with the decentralized trust model.

## Decision

Membership transitions use a majority certificate from the controllers in the
previous epoch.

1. A proposal contains the complete next roster and the exact identities of
   the previous-epoch controllers.
2. Every controller may sign at most one proposal digest for a given trust
   group and previous epoch. The vote is durable before the signature is
   returned.
3. A transition commits only with `floor(controllerCount / 2) + 1` distinct,
   valid controller signatures.
4. A replica verifies that the certificate's previous-controller set exactly
   matches its current trusted controller set before applying it.
5. There is no fixed leader. Any controller may propose and collect votes.
6. The application data plane remains available offline. Only membership
   mutation waits for a controller majority.

Majorities intersect, so two conflicting proposals cannot both obtain valid
certificates unless a controller violates the durable one-vote rule or its key
is compromised.

## Availability and operating guidance

- One controller: quorum is 1. Suitable only for bootstrap, with no controller
  redundancy.
- Two controllers: quorum is 2. Safe, but both must be online for membership
  changes.
- Three controllers: quorum is 2. Recommended default; one controller may be
  offline while another device is revoked or added.
- Four controllers: quorum is 3. Adding controllers changes both trust and
  availability and therefore remains an audited membership transition.

An unavailable quorum never blocks chat, project edits, local agent lifecycle,
or later anti-entropy. It blocks only trust-roster mutation.

Two controllers can concurrently author different proposals and durably spend
their one vote on opposite digests. This is a safe, non-committed state rather
than a fork: neither proposal has a majority certificate. With the recommended
three-controller roster, bring the third current controller online and retry
the intended proposal; its vote gives exactly one proposal the required
majority and advances the epoch. The product reports this as a proposal
conflict, distinct from an unreachable quorum. Votes are never deleted or
silently reassigned because an approval may already exist on an offline peer.

## Compatibility and activation

Version-one transition history remains decodable and signature-verifiable.
Upgraded replicas create version-two quorum proposals. A quorum-certified v2
transition activates a persisted policy requiring v2 for every subsequent
epoch. New trust groups activate the policy at epoch 1.

Activation must happen only after every retained controller runs a v2-capable
build. Until activation, the UI reports membership as “legacy single-signer”
and production acceptance is not complete.

## Rejected alternatives

- Last writer wins: permits trust rollback and order-dependent authorization.
- Lowest proposal hash wins: requires unsafe same-epoch rollback after commands
  or events may already have been accepted.
- Permanent leader/controller: centralizes availability and recovery.
- Gossip alone: improves dissemination but does not decide between two valid,
  conflicting security proposals.

## Verification requirements

Production acceptance requires all of the following:

- a two-replica opposite-delivery-order test;
- a three-controller concurrent-proposal test proving at most one certificate;
- restart/replay proof for the durable one-vote journal;
- rejection of forged, duplicate, stale, minority, and wrong-controller-set
  certificates;
- a live 2-of-3 revoke test across Mac mini, home-ts, and iPhone;
- proof that chat and local writes remain available while quorum is absent.
