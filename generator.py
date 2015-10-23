import os, time, json
import itertools

from utils import *

data_dir = '/home/pastafarianist/mu_roomy_data'
path_template = '%d'
file_template = '%d.dat'

canonical_file = 'canonical.pickle'

hands5 = [list_to_binary(combo) for combo in itertools.combinations(range(24), 5)]


def get_directory(state):
	return os.path.join(data_dir, path_template % state.score)

def get_filename(state):
	return file_template % state.hand

def get_path(state):
	return os.path.join(get_directory(state), get_filename(state))

def reset_storage(state):
	# assumes that the path exists but the file doesn't
	pass

def ensure_initialized(state):
	directory = get_directory(state)
	if not os.path.exists(directory):
		os.makedirs(directory)
	elif not os.path.isdir(directory):
		raise RuntimeError("%s exists but is not a directory" % directory)

	path = get_path(state)
	if not os.path.exists(path):
		reset_storage(state)

# def store(score, hand, deck, prob):

# 	if not os.path.exists(file_path):

masks = ((1 << 8) - 1, ((1 << 8) - 1) << 8, ((1 << 8) - 1) << 16)

def apply_permutation(num, perm):
	new_num = (num & masks[perm[0]]) >> (perm[0] * 8)
	new_num |= (((num & masks[perm[1]]) >> (perm[1] * 8)) << 8)
	new_num |= (((num & masks[perm[2]]) >> (perm[2] * 8)) << 16)
	return new_num

def retrieve_color(num, idx):
	return (num & masks[idx]) >> (idx * 8)

def canonicalize_fast(state):
	# Returns a new state.
	# Algorithm:
	# 1) Calculate the number of cards of each color in hand
	# 2) Sort these numbers in ascending order
	# 3a) If all numbers are different, take the resulting permutation of indices
	# 3b) Otherwise, compare the bitmasks of remaining cards in the deck
	#     as binary numbers and permute states accordingly

	nums = [
		(num_ones(state.hand & masks[0]), 0),
		(num_ones(state.hand & masks[1]), 1),
		(num_ones(state.hand & masks[2]), 2)
	]

	assert nums[0][0] + nums[1][0] + nums[2][0] == 5

	nums.sort()

	assert nums[2][0] >= 2, (nums, state)

	if nums[2][0] == 2:
		# 1, 2, 2 -> tie
		assert nums[0][0] == 1 and nums[1][0] == 2, nums
		if retrieve_color(state.deck, nums[1][1]) <= retrieve_color(state.deck, nums[2][1]):
			perm_idx = (0, 1, 2)
		else:
			perm_idx = (0, 2, 1)
	elif nums[2][0] == 3:
		if nums[1][0] == 1:
			# 1, 1, 3 -> tie
			assert nums[0][0] == 1, nums
			if retrieve_color(state.deck, nums[0][1]) <= retrieve_color(state.deck, nums[1][1]):
				perm_idx = (0, 1, 2)
			else:
				perm_idx = (1, 0, 2)
		elif nums[1][0] == 2:
			# 0, 2, 3 -> ok
			assert nums[0][0] == 0, nums
			perm_idx = (0, 1, 2)
		else:
			assert False, nums
	elif nums[2][0] == 4:
		# 0, 1, 4
		assert nums[0][0] == 0 and nums[1][0] == 1, nums
		perm_idx = (0, 1, 2)
	else:
		# 0, 0, 5 -> tie
		assert nums[0][0] == 0 and nums[1][0] == 0, (nums, state)
		if retrieve_color(state.deck, nums[0][1]) <= retrieve_color(state.deck, nums[1][1]):
			perm_idx = (0, 1, 2)
		else:
			perm_idx = (1, 0, 2)

	permutation = [nums[v][1] for v in perm_idx]

	new_hand = apply_permutation(state.hand, permutation)
	new_deck = apply_permutation(state.deck, permutation)

	return State(state.score, new_hand, new_deck)

def canonicalize(state):
	equiv_class = [(apply_permutation(state.hand, p), apply_permutation(state.deck, p)) for p in (
		(0, 1, 2),
		(0, 2, 1),
		(1, 0, 2),
		(1, 2, 0),
		(2, 0, 1),
		(2, 1, 0)
	)]

	equiv_class.sort()
	return State(state.score, equiv_class[0][0], equiv_class[0][1])

def expand_deck(hand, deck):
	res = 0
	i = 0
	while deck:
		if not (hand & 1):
			res |= ((deck & 1) << i)
			deck >>= 1
		hand >>= 1
		i += 1
	return res

def precalc():
	canonical_path = os.path.join(data_dir, canonical_file)
	load_canonical(canonical_path)
	try:
		time_start = time.time()
		for i, hand in enumerate(hands5):
			if i % 10 == 0 and i > 0:
				elapsed = time.time() - time_start
				speed = elapsed / i
				remaining = (len(hands5) - i) / (speed * 60)
				print('%d/%d hands processed in %.1fs. %.2f s/hand. %.1f minutes remaining.' % (i, len(hands5), elapsed, speed, remaining))
			for deck in range(1 << 19):
				if hand & deck:
					continue
				state = State(0, hand, deck)
				cstate = canonicalize_calc(state)
				canonical_cache[state] = cstate
	except KeyboardInterrupt:
		save_canonical(canonical_path)

def main():
	precalc()

if __name__ == '__main__':
	main()
