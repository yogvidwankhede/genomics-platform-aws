import gzip

from gp_research.io import read_genotypes, read_happy_vcf


def _write(path, lines):
    with gzip.open(path, "wt") as fh:
        fh.write("\n".join(lines) + "\n")


def test_read_happy_vcf(tmp_path):
    p = tmp_path / "x.happy.vcf.gz"
    _write(
        p,
        [
            "##fileformat=VCFv4.2",
            "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tTRUTH\tQUERY",
            "chr20\t100\t.\tA\tG\t.\t.\t.\tGT:BD:BVT\t0/1:TP:SNP\t0/1:TP:SNP",
            "chr20\t200\t.\tAT\tA\t.\t.\t.\tGT:BD:BVT\t0/1:FN:INDEL\t./.:.:NOCALL",
            "chr20\t300\t.\tC\tT\t.\t.\t.\tGT:BD:BVT\t./.:.:NOCALL\t0/1:FP:SNP",
        ],
    )
    recs = list(read_happy_vcf(p))
    assert [(r.pos, r.side, r.label, r.vtype) for r in recs] == [
        (100, "TRUTH", "TP", "SNP"),
        (100, "QUERY", "TP", "SNP"),
        (200, "TRUTH", "FN", "INDEL"),
        (300, "QUERY", "FP", "SNP"),
    ]


def test_read_genotypes_pass_only_and_split(tmp_path):
    p = tmp_path / "calls.vcf.gz"
    _write(
        p,
        [
            "#CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tS",
            "chr20\t10\t.\tA\tG\t50\tPASS\t.\tGT\t0/1",
            "chr20\t20\t.\tC\tT\t5\tLowQual\t.\tGT\t1/1",
            "chr20\t30\t.\tG\tA,C\t50\tPASS\t.\tGT\t1/2",
            "chr20\t40\t.\tT\tC\t50\tPASS\t.\tGT\t./.",
        ],
    )
    g = read_genotypes(p)
    assert g == {
        ("chr20", 10, "A", "G"): (0, 1),
        ("chr20", 30, "G", "A"): (0, 1),
        ("chr20", 30, "G", "C"): (0, 1),
    }
