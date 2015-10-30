#!/usr/bin/python3

from __future__ import division
import csv, time, os, json
from collections import defaultdict
import generator as gen
from utils import *


def calc_factorization_for_values(hand_values):
    num_states = 0
    used = set()
    factor = defaultdict(lambda: [0] * (2**19))
    for colors_i in range(int('100000', 3)):
        colors = [int(v) for v in to_base(colors_i, 3, zfill=5)]

        hand = 0
        for v, c in zip(hand_values, colors):
            hand |= (1 << (v + c * 8))

        if num_ones(hand) != 5:
            continue

        if hand in used:
            continue
        else:
            used.add(hand)

        print("With colors: %r hand %r becomes: %s" % (colors, hand_values, cardset_to_str(hand)))

        for compact_deck in range(1 << 19):
            deck = gen.expand_deck(hand, compact_deck)
            assert not (hand & deck)
            state = gen.State(0, hand, deck)
            num_states += 1
            cstate = gen.canonicalize(state)
            factor[cstate.hand][gen.compactify_deck(cstate.hand, cstate.deck)] = 1

    return factor, num_states

def calc_factorization():
    values = (
        (0, 0, 0, 1, 1),
        (0, 0, 0, 1, 2),
        (0, 1, 1, 2, 2),
        (0, 1, 2, 3, 3),
        (0, 1, 2, 3, 4)
    )

    factorization = [None] * 5
    time_start = time.time()

    for i, hand_values in enumerate(values):
        time_cycle_start = time.time()

        factor, num_states = calc_factorization_for_values(hand_values)
        num_cstates = sum(sum(v) for v in factor.values())

        to_store = {k : (None if sum(v) == len(v) else v) for k, v in factor.items()}
        factorization[i] = (to_store, num_states)

        time_for_cycle = time.time() - time_cycle_start
        total_time = time.time() - time_start

        print("For hand values %r:" % (hand_values, ))
        print("  Total hands in factor: %d" % len(factor))
        print("  Total states in factor: %d" % num_cstates)
        print("  Total states without factorization: %d" % num_states)
        print("  Total time to calculate that: %.2f seconds (%.2f minutes)" % (time_for_cycle, time_for_cycle / 60))
        print("  Total time elapsed since start: %.2f seconds (%.2f minutes)" % (total_time, total_time / 60))

    with open(gen.factorization_path, 'w') as f:
        dump(factorization, f)

hand_values_data_1 = defaultdict(int)

def calc_storage_size(factorization):
    data = []
    for factor, num_states in factorization:
        num_cstates = sum((2**19 if v is None else sum(v)) for v in factor.values())
        data.append(num_cstates)
    print(data)

    total_size = 0

    done = set()
    total = int('100000', 8)
    for hand_v in range(total):
        hand_values = tuple(sorted(int(v) for v in to_base(hand_v, 8, zfill=5)))
        assert len(hand_values) == 5, hand_values

        # if hand_v % 10000 == 0 and hand_v > 0:
        #     elapsed = time.time() - time_start
        #     speed = elapsed / hand_v
        #     remaining = (total - hand_v) * hand_v / (elapsed * 60)
        #     print('%d/%d hands processed in %.1fs. Current: %r. %.2f s/hand. %.1f minutes remaining.' % 
        #         (hand_v, total, elapsed, hand_values, speed, remaining))

        if hand_values in done:
            # Because I sort the digits too.
            continue
        else:
            done.add(hand_values)

        if not are_valid_values(hand_values):
            continue

        size_of_values = data[categorize_values(hand_values)]
        hand_values_data_1[hand_values] = size_of_values
        total_size += size_of_values

    print("Total number of elements in the table for 1 score: %d" % total_size)
    print("Total size of the table for 1 score: %d bytes" % (total_size * 2))
    print("Total size of the table for 1 score: %.2f Gb" % ((total_size * 2) / (1 << 30)))
    print("Difference from 7 Gb: %.2f Mb" % (((7 * (1 << 30)) - total_size * 2) / (1 << 20)))

    # 7428112384 = binom(24, 5) * 2^19 * 2 / 6
    print("Expected with perfect factorization: %d bytes, %.2f Gb" % (7428112384, 7428112384 / (1 << 30)))
    print("Deficiency: %d bytes, %.2f Mb" % (total_size * 2 - 7428112384, (total_size * 2 - 7428112384) / (1 << 20)))

    return total_size

hand_values_data_2 = defaultdict(int)

def hand_storage_format(hand, factorization):
    # 1) Convert hand to hand_values
    # 2) Classify hand_values as one of 5 types
    # TODO: are the following two ideas implementable?
    # 3) Figure out coloring to get from hand_values to hand
    # 4) Use lookup table to see how many decks that coloring contains
    hand_values = [card % 8 for card in binary_to_list(hand)]
    values_type = categorize_values(hand_values)

    # Actually, need to distinguish between 3 values here:
    # 0, 2**19 and the special value which is unique for each type.

    state = gen.State(0, hand, 0)
    cstate = gen.canonicalize(state)

    if cstate.hand == hand:
        # TODO: optimize
        # TODO: is there any other way to calculate this besides
        # measuring the size of the equivalence class?
        sz = len(set(gen.equiv_class(state)))
        if sz == 6:
            decks_per_hand = 1 << 19
        else:
            # TODO: luckily, there is only one canonical hand in each type
            # with fewer than 2**19 states, and it can be detected due to
            # the fact that its equivalence class has fewer than 6 elements.
            # Under which circumstances this wouldn't be the case?
            d = factorization[values_type][0]
            l = [v for v in d.values() if v is not None]
            assert len(l) == 1
            decks_per_hand = sum(l[0])
    else:
        decks_per_hand = 0

    hand_values_data_2[tuple(sorted(hand_values))] += decks_per_hand

    return decks_per_hand, values_type
    

def calc_allocation():
    with open(gen.factorization_path, 'r') as f:
        factorization = json.load(f)

    total_size = calc_storage_size(factorization)

    offsets = [0]
    types = []

    for hand in gen.hands5:
        decks_per_hand, values_type = hand_storage_format(hand, factorization)
        offsets.append(offsets[-1] + decks_per_hand)
        types.append(values_type)

    last_offset = offsets.pop()
    assert last_offset == total_size, (last_offset, total_size, last_offset - total_size)

    allocation = list(zip(offsets, types))

    with open(gen.allocation_path, 'w') as f:
        dump(allocation, f)


if __name__ == '__main__':
    # calc_factorization()
    calc_allocation()

    print(len(hand_values_data_1))
    print(len(hand_values_data_2))

    for key in hand_values_data_1:
        assert key in hand_values_data_2, key

    for key in hand_values_data_2:
        assert key in hand_values_data_1, key

    for key in hand_values_data_1:
        assert hand_values_data_1[key] == hand_values_data_2[key], (key, hand_values_data_1[key], hand_values_data_2[key])