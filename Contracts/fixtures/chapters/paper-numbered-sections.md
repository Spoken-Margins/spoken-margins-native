# Sparse Retrieval at Scale

## Abstract

We study retrieval over a corpus of one billion passages and show that a sparse index with learned term weights matches a dense index at a fraction of the memory cost.

## 1 Introduction

Retrieval systems are the front end of most question answering stacks. Their cost grows with the corpus, so small gains in index size matter.

## 2 Related Work

Earlier work compared lexical and dense retrieval on small collections. We extend those comparisons to web scale.

### 2.1 Lexical methods

Inverted indexes with term-frequency weighting remain strong baselines.

### 2.2 Dense methods

Bi-encoders map queries and passages to vectors and search them by inner product.

## 3 Method

We learn a weight for each term from click data and prune terms whose weight falls below a threshold.

### 3.1 Training

Weights are trained with a contrastive loss over mined negatives.

### 3.2 Pruning

Pruning is done per posting list so that frequent terms keep more entries.

## 4 Experiments

We report recall at one hundred and index size on three public benchmarks.

## 5 Conclusion

Learned sparse weights are a practical default when memory is the constraint.

## References

[1] Example Author. Term weighting revisited. 2019.
[2] Example Author. Dense passage ranking. 2020.
[3] Example Author. Scaling inverted indexes. 2022.
