(declare-sort a 0)
(declare-datatypes (b) ((box (make_box))))
(assert-not (forall ((xs (box a)) (ys (box a))) (= xs ys)))
(check-sat)
