context("Test predictNMD functions")

data(query_exons)
data(query_cds)

test_that("Test .testNMD", {
  out <- .testNMD(query_exons[1], query_cds[1], 50, FALSE)
  expect_equal(out$is_NMD, FALSE)
  expect_equal(out$stop_to_lastEJ, -130)
  expect_equal(out$`3'UTR_length`, 1158)

  out <- .testNMD(query_exons[3], query_cds[3], 50, FALSE)
  expect_equal(out$is_NMD, TRUE)
  expect_equal(out$stop_to_lastEJ, 364)
  expect_equal(out$`3'UTR_length`, 644)
  # expect_equal(out$stop_to_downEJs, "69,286,364")
})

test_that("Test proper input arguments", {
  expect_error(predictNMD(query_exons[[1]], cds = query_cds))
  expect_error(predictNMD(query_exons[[1]], cds = q2rcovs))
  expect_error(predictNMD(q2r, cds = q2rcovs))
})

test_that("Test the structure of outputs", {
  out1 <- predictNMD(query_exons, cds = query_cds)
  expect_equal(names(out1), c(
    "transcript", "stop_to_lastEJ",
    "num_of_downEJs",
    "3'UTR_length", "is_NMD", "PTC_coord"
  ))
  expect_equal(nrow(out1), 4)
})
