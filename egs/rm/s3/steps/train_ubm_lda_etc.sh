#!/bin/bash
# Copyright 2010-2011 Microsoft Corporation

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
# THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION ANY IMPLIED
# WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR PURPOSE,
# MERCHANTABLITY OR NON-INFRINGEMENT.
# See the Apache 2 License for the specific language governing permissions and
# limitations under the License.


# Train UBM from a trained HMM/GMM system [with splice+LDA+[MLLT/ET/MLLT+SAT] features]
# Alignment directory is used for the CMN and transforms.

if [ $# != 5 ]; then
   echo "Usage: steps/train_ubm_lda_mllt.sh <ubm-numcomps> <data-dir> <lang-dir> <ali-dir> <exp-dir>"
   echo " e.g.: steps/train_ubm_lda_mllt.sh data/train data/lang exp/tri2b_ali exp/ubm3d"
   exit 1;
fi

if [ -f path.sh ]; then . path.sh; fi

numcomps=$1
data=$2
lang=$3
alidir=$4
dir=$5

mkdir -p $dir
mat=$alidir/final.mat


feats="ark:apply-cmvn --norm-vars=false --utt2spk=ark:$data/utt2spk ark:$alidir/cmvn.ark scp:$data/feats.scp ark:- | splice-feats ark:- ark:- | transform-feats $alidir/final.mat ark:- ark:- |"

if [ -f $alidir/trans.ark ]; then
   echo "Running with speaker transforms $alidir/trans.ark"
   feats="$feats transform-feats --utt2spk=ark:$data/utt2spk ark:$alidir/trans.ark ark:- ark:- |"
fi

[ $numcomps -gt 2000 ] && echo "Cannot have num components >2k (or change script)" \
  && exit 1;

init-ubm --intermediate-numcomps=2000 --ubm-numcomps=$numcomps --verbose=2 \
    --fullcov-ubm=true $alidir/final.mdl $alidir/final.occs \
    $dir/0.ubm 2> $dir/cluster.log

# First do Gaussian selection to 50 components, which will be used
# as the initial screen for all further passes.
gmm-gselect --n=50 "fgmm-global-to-gmm $dir/0.ubm - |" "$feats" \
   "ark:|gzip -c >$dir/gselect_diag.gz" 2>$dir/gselect_diag.log

# Do four iterations of full-covariance training.
# On each iteration, first limit with diagonal-cov models to
# a 15-Gaussian subset of the original 50-Gaussian subset.

for x in 0 1 2 3; do
    echo "Pass $x"
    ( gmm-gselect "--gselect=ark:gunzip -c $dir/gselect_diag.gz|" \
      "fgmm-global-to-gmm $dir/$x.ubm - |" "$feats" ark:- | \
       fgmm-global-acc-stats --gselect=ark:- $dir/$x.ubm "$feats" $dir/$x.acc ) \
  	2> $dir/acc.$x.log  || exit 1;
    fgmm-global-est --verbose=2 $dir/$x.ubm $dir/$x.acc \
 	$dir/$[$x+1].ubm 2> $dir/update.$x.log || exit 1;
    rm $dir/$x.acc $dir/$x.ubm
done

mv $dir/4.ubm $dir/final.ubm || exit 1;


