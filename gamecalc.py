import itertools
from collections import namedtuple

# meanings of card numbers:
# 0-7 = red cards 1-8
# 8-15 = blue cards 1-8
# 16-24 = yellow cards 1-8

def score_combination(combo):
	if combo in score_cache:
		return score_cache[combo]
	rem = sorted(v % 8 for v in combo)
	if combo[0] // 8 == combo[1] // 8 == combo[2] // 8 and rem[0] == rem[1] - 1 == rem[2] - 2:
		# same color, consecutive
		return (rem[0]) * 10 + 50
	elif rem[0] == rem[1] == rem[2]:
		# same numbers
		return (rem[0]) * 10 + 20
	elif rem[0] == rem[1] - 1 == rem[2] - 2:
		# different colors, consecutive
		return (rem[0]) * 10 + 10
	assert False, ', '.join(pretty_name(card) for card in combo)

def card_combinations(hand):

	v2c = [[] for _ in range(8)]
	for card in hand:
		v2c[card % 8].append(card // 8)

	# different colors, consecutive
	for v in range(6):
		if v2c[v] and v2c[v + 1] and v2c[v + 2]:
			for col1 in v2c[v]:
				for col2 in v2c[v + 1]:
					for col3 in v2c[v + 2]:
						if col1 == col2 == col3:
							score = v * 10 + 50
						else:
							score = v * 10 + 10
						combo = (v + col1 * 8, v + 1 + col2 * 8, v + 2 + col3 * 8)
						assert score_combination(combo) == score, 'combo: %r, score: %d, score_combination(combo): %d' % (combo, score, score_combination(combo))
						score_cache[combo] = score
						yield score, combo

	# same numbers
	for v, colors in enumerate(v2c):
		if len(colors) == 3:
			score = v * 10 + 20
			combo = (v + colors[0] * 8, v + colors[1] * 8, v + colors[2] * 8)
			assert score_combination(combo) == score, 'combo: %r, score: %d, score_combination(combo): %d' % (combo, score, score_combination(combo))
			score_cache[combo] = score
			yield score, combo

def moves(hand, deck_not_empty):
	if deck_not_empty:
		for card in hand:
			yield ('remove', card, 0)
	if len(hand) >= 3:
		for score_change, cards in combinations_cache[tuple(hand)]:
			yield ('deal', cards, score_change)


def outcomes(hand, deck, score, action, parameter, score_change):
	new_score = score + score_change
	if action == 'remove':
		new_hand_partial = [card for card in hand if card != parameter]
		if deck:
			for replacement in deck:
				new_hand = new_hand_partial + [replacement]
				new_hand.sort()
				new_deck = [card for card in deck if card != replacement]
				yield new_hand, new_deck, new_score
		else:
			yield new_hand_partial, deck, new_score
	elif action == 'deal':
		new_hand_partial = [card for card in hand if card not in parameter]
		if len(deck) > 3:
			for triple in itertools.combinations(deck, 3):
				new_hand = new_hand_partial + list(triple)
				new_hand.sort()
				new_deck = [card for card in deck if card not in triple]
				yield new_hand, new_deck, new_score
		else:
			new_hand = new_hand_partial + deck
			new_hand.sort()
			yield new_hand, [], new_score
	else:
		assert False

score_cache = {}
combinations_cache = {
	tuple(hand) : list(card_combinations(hand)) for hand in
	itertools.chain(
		itertools.combinations(range(24), 5),
		itertools.combinations(range(24), 4),
		itertools.combinations(range(24), 3),
	)
}


# import json

# with open('scores.json', 'w') as f:
# 	json.dump(score_cache, f)

# with open('combinations.json', 'w') as f:
# 	json.dump(combinations_cache, f)

# combos = {}

# for k, v in score_cache.items():
# 	if v not in combos:
# 		combos[v] = []
# 	combos[v].append(k)

# for v, k in sorted(combos.items()):
# 	print(v)
# 	for combo in k:
# 		print(' %s' % ', '.join(pretty_name(card) for card in combo))
