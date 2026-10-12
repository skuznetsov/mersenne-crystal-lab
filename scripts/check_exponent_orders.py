#!/usr/bin/env python3
"""Rebuild a bounded multiplicative-order oracle by first-return doubling."""

import argparse
import hashlib
import json
import math
from pathlib import Path

LIMIT = 65_535
LAW_QS = [1, 3, 5, 7, 9, 11, 13, 15, 17, 21, 33, 35, 65, 91, 127]
LOW_QS = [1, 3, 5, 7, 13]
SCOPE = "all odd primes <= 65535 (actual maximum 65521)"


def odd_primes(limit: int) -> list[int]:
    prime = bytearray(b"\x01") * (limit + 1)
    prime[0:2] = b"\x00\x00"
    for p in range(2, math.isqrt(limit) + 1):
        if prime[p]:
            prime[p * p : limit + 1 : p] = b"\x00" * (((limit - p * p) // p) + 1)
    return [p for p in range(3, limit + 1, 2) if prime[p]]


def is_prime(n: int) -> bool:
    if n < 2:
        return False
    for d in range(2, math.isqrt(n) + 1):
        if n % d == 0:
            return False
    return True


def first_return_order(p: int) -> int:
    residue = 1
    count = 0
    while True:
        residue = (2 * residue) % p
        count += 1
        if residue == 1:
            return count


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="results/order_oracle.regenerated.json")
    args = parser.parse_args()

    primes = odd_primes(LIMIT)
    orders: dict[str, int] = {}
    iterations: dict[str, int] = {}
    histogram: dict[str, int] = {}
    total_doublings = 0
    for p in primes:
        r = first_return_order(p)
        orders[str(p)] = r
        iterations[str(p)] = r
        histogram[str(r)] = histogram.get(str(r), 0) + 1
        total_doublings += r

    checks = 0
    for q in LAW_QS:
        for p in primes:
            residue = 1
            for _ in range(q):
                residue = (2 * residue) % p
            assert (residue == 1) == (q % orders[str(p)] == 0), (p, q, residue)
            checks += 1

    odd_orders = {r for r in orders.values() if r % 2}
    odd_order_primes = sum(r % 2 for r in orders.values())
    order_payload = {
        "scope": SCOPE,
        "prime_limit": LIMIT,
        "primes": primes,
        "orders_by_prime": orders,
        "iterations_by_prime": iterations,
    }
    canonical = json.dumps(order_payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    result = {
        "schema": "mpgs-order-oracle-v1",
        **order_payload,
        "order_histogram": histogram,
        "counts": {
            "odd_primes": len(primes),
            "maximum_prime": primes[-1],
            "total_modular_doublings": total_doublings,
            "distinct_order_count": len(histogram),
            "odd_order_prime_count": odd_order_primes,
            "even_order_prime_count_omitted_for_odd_q": len(primes) - odd_order_primes,
            "distinct_odd_order_count": len(odd_orders),
            "distinct_odd_composite_order_count": sum(not is_prime(r) for r in odd_orders),
            "law_check_cases": checks,
            "law_check_exponents": LAW_QS,
        },
        "method": {
            "prime_generation": "Sieve of Eratosthenes over integers 2..65535; emit odd primes.",
            "minimal_order": "Start at residue=1; repeatedly double modulo p; count to the first return to 1.",
            "iteration_semantics": "iterations_by_prime[p] counts modular doublings to the first return, equal to the minimal order.",
            "law_checks": "For each listed q and admitted p, double q times modulo p and compare return-to-1 with ord_p(2)|q.",
            "excluded_methods": ["factor reduction of p-1", "mersenne-lab pow2_mod", "construction of high-exponent 2^q-1 integers"],
        },
        "provenance": {
            "algorithm_id": "python-repeated-modular-doubling-first-return-v1",
            "python_version": __import__("platform").python_version(),
            "canonical_json_sha256": digest,
            "hash_scope": "UTF-8 canonical compact JSON with sorted keys over scope, prime_limit, primes, orders_by_prime, iterations_by_prime.",
        },
        "low_exponent_proper_factor_checks": {
            str(q): {
                "small_mersenne_value": (1 << q) - 1,
                "order_matching_primes": [p for p in primes if q % orders[str(p)] == 0],
                "proper_trial_factors": [p for p in primes if q % orders[str(p)] == 0 and p < (1 << q) - 1],
            }
            for q in LOW_QS
        },
    }
    Path(args.output).write_text(json.dumps(result, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    print(f"output={args.output}")
    print(f"primes={len(primes)} max_prime={primes[-1]} doublings={total_doublings}")
    print(f"odd_order_primes={odd_order_primes} distinct_odd_orders={len(odd_orders)}")
    print(f"law_checks={checks} canonical_sha256={digest}")


if __name__ == "__main__":
    main()
