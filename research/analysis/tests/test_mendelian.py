from gp_research.mendelian import Regions, intersect, is_consistent, mendelian_violations


def test_consistency_rules():
    assert is_consistent((0, 1), (0, 1), (0, 0))
    assert is_consistent((1, 1), (0, 1), (0, 1))
    assert not is_consistent((1, 1), (0, 0), (0, 1))  # child hom-alt, father hom-ref
    assert not is_consistent((0, 1), (0, 0), (0, 0))  # de novo / error


def test_regions_contains_uses_bed_semantics():
    r = Regions([("chr1", 10, 20)])
    assert not r.contains("chr1", 10)  # VCF pos 10 == BED base 9
    assert r.contains("chr1", 11)
    assert r.contains("chr1", 20)
    assert not r.contains("chr1", 21)
    assert not r.contains("chr2", 15)


def test_intersect():
    a = [("chr1", 0, 100), ("chr1", 200, 300)]
    b = [("chr1", 50, 250)]
    assert intersect(a, b) == [("chr1", 50, 100), ("chr1", 200, 250)]


def test_violation_rate_with_missing_as_ref():
    regions = Regions([("chr1", 0, 1000)])
    child = {("chr1", 10, "A", "G"): (0, 1), ("chr1", 20, "C", "T"): (0, 1), ("chr1", 5000, "A", "C"): (0, 1)}
    father = {("chr1", 10, "A", "G"): (0, 1)}
    mother = {}
    out = mendelian_violations(child, father, mother, regions)
    # site 20: child het, both parents (missing => 0/0) -> violation; site 5000 outside regions
    assert out == {"sites": 2, "violations": 1, "violation_rate": 0.5}
