# distutils: extra_compile_args = -O2 -w
# distutils: include_dirs = pylds/
# cython: boundscheck = False, nonecheck = False, wraparound = False, cdivision = True

import numpy as np
from numpy.lib.stride_tricks import as_strided

cimport numpy as np
cimport cython
from libc.math cimport log
from numpy.math cimport INFINITY, PI

from blas_lapack cimport dsymm, dcopy, dgemm, dpotrf, \
        dgemv, dpotrs, daxpy, dtrtrs, dsyrk, dtrmv, \
        dger, dnrm2

# NOTE: because the matrix operations are done in Fortran order but the code
# expects C ordered arrays as input, the BLAS and LAPACK function calls mark
# matrices as transposed. temporaries, which don't get sliced, are left in
# Fortran order, and their memoryview types are consistent. for symmetric
# matrices, F/C order doesn't matter.
# NOTE: I tried the dsymm / dsyrk version and it was slower, even for larger p!
# NOTE: using typed memoryview syntax instead of raw pointers is like 1.5-3%
# slower due to struct passing overhead, but much prettier
# NOTE: scipy doesn't expose a dtrsm binding

# TODO nonstationary versions
# TODO try an Eigen version! faster for small matrices (numerically and in
# function call overhead)
# TODO use info form when p > n
# TODO cholesky update/downdate versions (square root filter)
# TODO generate single-precision codepath?


def kalman_filter(
    double[:] mu_init, double[:,:] sigma_init,
    double[:,:,:] A, double[:,:,:] sigma_states,
    double[:,:,:] C, double[:,:,:] sigma_obs,
    double[:,::1] data):

    # allocate temporaries and internals
    cdef int T = C.shape[0], p = C.shape[1], n = C.shape[2]
    cdef int t

    cdef double[::1] mu_predict = np.copy(mu_init)
    cdef double[:,:] sigma_predict = np.copy(sigma_init)

    cdef double[::1,:] temp_pp = np.empty((p,p),order='F')
    cdef double[::1,:] temp_pn = np.empty((p,n),order='F')
    cdef double[::1]   temp_p  = np.empty((p,), order='F')
    cdef double[::1,:] temp_nn = np.empty((n,n),order='F')

    # allocate output
    cdef double[:,::1] filtered_mus = np.empty((T,n))
    cdef double[:,:,::1] filtered_sigmas = np.empty((T,n,n))
    cdef double ll = 0.

    # run filter forwards
    for t in range(T):
        ll += condition_on(
            mu_predict, sigma_predict, C[t], sigma_obs[t], data[t],
            filtered_mus[t], filtered_sigmas[t],
            temp_p, temp_pn, temp_pp)
        predict(
            filtered_mus[t], filtered_sigmas[t], A[t], sigma_states[t],
            mu_predict, sigma_predict,
            temp_nn)
        pass

    return ll, np.asarray(filtered_mus), np.asarray(filtered_sigmas)


def rts_smoother(
    double[::1] mu_init, double[:,::1] sigma_init,
    double[:,:,:] A, double[:,:,:] sigma_states,
    double[:,:,:] C, double[:,:,:] sigma_obs,
    double[:,::1] data):

    # allocate temporaries and internals
    cdef int T = C.shape[0], p = C.shape[1], n = C.shape[2]
    cdef int t

    cdef double[:,::1] mu_predicts = np.empty((T+1,n))
    cdef double[:,:,:] sigma_predicts = np.empty((T+1,n,n))

    cdef double[::1,:] temp_pp  = np.empty((p,p),order='F')
    cdef double[::1,:] temp_pn  = np.empty((p,n),order='F')
    cdef double[::1,:] temp_nn  = np.empty((n,n),order='F')
    cdef double[::1,:] temp_nn2 = np.empty((n,n),order='F')
    cdef double[::1]   temp_p   = np.empty((p,), order='F')

    # allocate output
    cdef double[:,::1] smoothed_mus = np.empty((T,n))
    cdef double[:,:,::1] smoothed_sigmas = np.empty((T,n,n))
    cdef double ll = 0.

    # run filter forwards, saving predictions
    mu_predicts[0] = mu_init
    sigma_predicts[0] = sigma_init
    for t in range(T):
        ll += condition_on(
            mu_predicts[t], sigma_predicts[t], C[t], sigma_obs[t], data[t],
            smoothed_mus[t], smoothed_sigmas[t],
            temp_p, temp_pn, temp_pp)
        predict(
            smoothed_mus[t], smoothed_sigmas[t], A[t], sigma_states[t],
            mu_predicts[t+1], sigma_predicts[t+1],
            temp_nn)

    # run rts update backwards, using predictions
    for t in range(T-2,-1,-1):
        rts_backward_step(
            A[t], sigma_states[t],
            smoothed_mus[t], smoothed_sigmas[t],
            mu_predicts[t+1], sigma_predicts[t+1],
            smoothed_mus[t+1], smoothed_sigmas[t+1],
            temp_nn, temp_nn2)

    return ll, np.asarray(smoothed_mus), np.asarray(smoothed_sigmas)


def filter_and_sample(
    double[:] mu_init, double[:,:] sigma_init,
    double[:,:,:] A, double[:,:,:] sigma_states,
    double[:,:,:] C, double[:,:,:] sigma_obs,
    double[:,::1] data):

    # allocate temporaries and internals
    cdef int T = C.shape[0], p = C.shape[1], n = C.shape[2]
    cdef int t

    cdef double[::1] mu_predict = np.copy(mu_init)
    cdef double[:,:] sigma_predict = np.copy(sigma_init)

    cdef double[::1,:] temp_pp = np.empty((p,p),order='F')
    cdef double[::1,:] temp_pn = np.empty((p,n),order='F')
    cdef double[::1]   temp_p  = np.empty((p,), order='F')
    cdef double[::1,:] temp_nn = np.empty((n,n),order='F')
    cdef double[::1]   temp_n  = np.empty((n,), order='F')

    cdef double[:,::1] filtered_mus = np.empty((T,n))
    cdef double[:,:,::1] filtered_sigmas = np.empty((T,n,n))

    # allocate output and generate randomness
    cdef double[:,::1] randseq = np.random.randn(T,n)
    cdef double ll = 0.

    # run filter forwards
    for t in range(T):
        ll += condition_on(
            mu_predict, sigma_predict, C[t], sigma_obs[t], data[t],
            filtered_mus[t], filtered_sigmas[t],
            temp_p, temp_pn, temp_pp)
        predict(
            filtered_mus[t], filtered_sigmas[t], A[t], sigma_states[t],
            mu_predict, sigma_predict,
            temp_nn)

    # sample backwards
    sample_gaussian(filtered_mus[T-1], filtered_sigmas[T-1], randseq[T-1])
    for t in range(T-2,-1,-1):
        condition_on(
            filtered_mus[t], filtered_sigmas[t], A[t], sigma_states[t], randseq[t+1],
            filtered_mus[t], filtered_sigmas[t],
            temp_n, temp_nn, sigma_predict)
        sample_gaussian(filtered_mus[t], filtered_sigmas[t], randseq[t])

    return ll, np.asarray(randseq)


def E_step(
    double[:] mu_init, double[:,:] sigma_init,
    double[:,:,:] A, double[:,:,:] sigma_states,
    double[:,:,:] C, double[:,:,:] sigma_obs,
    double[:,::1] data):

    # NOTE: this is almost the same as the RTS smoother except
    #   1. we collect statistics along the way, and
    #   2. we use the RTS gain matrix to do it

    # allocate temporaries and internals
    cdef int T = C.shape[0], p = C.shape[1], n = C.shape[2]
    cdef int t

    cdef double[:,:] mu_predicts = np.empty((T+1,n))
    cdef double[:,:,:] sigma_predicts = np.empty((T+1,n,n))

    cdef double[::1,:] temp_pp  = np.empty((p,p),order='F')
    cdef double[::1,:] temp_pn  = np.empty((p,n),order='F')
    cdef double[::1,:] temp_nn  = np.empty((n,n),order='F')
    cdef double[::1,:] temp_nn2 = np.empty((n,n),order='F')
    cdef double[::1]   temp_p   = np.empty((p,), order='F')

    # allocate output
    cdef double[:,::1] smoothed_mus = np.empty((T,n))
    cdef double[:,:,::1] smoothed_sigmas = np.empty((T,n,n))
    cdef double[:,:,::1] ExxnT = np.empty((T-1,n,n))  # 'n' for next
    cdef double ll = 0.

    # run filter forwards, saving predictions
    mu_predicts[0] = mu_init
    sigma_predicts[0] = sigma_init
    for t in range(T):
        ll += condition_on(
            mu_predicts[t], sigma_predicts[t], C[t], sigma_obs[t], data[t],
            smoothed_mus[t], smoothed_sigmas[t],
            temp_p, temp_pn, temp_pp)
        predict(
            smoothed_mus[t], smoothed_sigmas[t], A[t], sigma_states[t],
            mu_predicts[t+1], sigma_predicts[t+1],
            temp_nn)

    # run rts update backwards, using predictions and setting E[x_t x_{t+1}^T]
    for t in range(T-2,-1,-1):
        rts_backward_step(
            A[t], sigma_states[t],
            smoothed_mus[t], smoothed_sigmas[t],
            mu_predicts[t+1], sigma_predicts[t+1],
            smoothed_mus[t+1], smoothed_sigmas[t+1],
            temp_nn, temp_nn2)
        set_dynamics_stats(
            smoothed_mus[t], smoothed_mus[t+1], smoothed_sigmas[t+1],
            temp_nn, ExxnT[t])

    return ll, np.asarray(smoothed_mus), np.asarray(smoothed_sigmas), np.asarray(ExxnT)


##########
#  util  #
##########


cdef inline double condition_on(
    # inputs
    double[:] mu_x, double[:,:] sigma_x,
    double[:,:] C, double[:,:] sigma_obs, double[:] y,
    # outputs
    double[:] mu_cond, double[:,:] sigma_cond,
    # temps
    double[:] temp_p, double[:,:] temp_pn, double[:,:] temp_pp,
    ) nogil:
    cdef int p = C.shape[0], n = C.shape[1]
    cdef int nn = n*n, pp = p*p
    cdef int inc = 1, info = 0
    cdef double one = 1., zero = 0., neg1 = -1., ll = 0.

    if y[0] != y[0]:  # nan check
        dcopy(&n, &mu_x[0], &inc, &mu_cond[0], &inc)
        dcopy(&nn, &sigma_x[0,0], &inc, &sigma_cond[0,0], &inc)
        return 0.
    else:
        # NOTE: the C arguments are treated as transposed because C is
        # assumed to be in C order
        dgemm('T', 'N', &p, &n, &n, &one, &C[0,0], &n, &sigma_x[0,0], &n, &zero, &temp_pn[0,0], &p)
        dcopy(&pp, &sigma_obs[0,0], &inc, &temp_pp[0,0], &inc)
        dgemm('N', 'N', &p, &p, &n, &one, &temp_pn[0,0], &p, &C[0,0], &n, &one, &temp_pp[0,0], &p)
        dpotrf('L', &p, &temp_pp[0,0], &p, &info)

        dcopy(&p, &y[0], &inc, &temp_p[0], &inc)
        dgemv('T', &n, &p, &neg1, &C[0,0], &n, &mu_x[0], &inc, &one, &temp_p[0], &inc)
        dtrtrs('L', 'N', 'N', &p, &inc, &temp_pp[0,0], &p, &temp_p[0], &p, &info)
        ll = (-1./2) * dnrm2(&p, &temp_p[0], &inc)**2
        dtrtrs('L', 'T', 'N', &p, &inc, &temp_pp[0,0], &p, &temp_p[0], &p, &info)
        if (&mu_x[0] != &mu_cond[0]):
            dcopy(&n, &mu_x[0], &inc, &mu_cond[0], &inc)
        dgemv('T', &p, &n, &one, &temp_pn[0,0], &p, &temp_p[0], &inc, &one, &mu_cond[0], &inc)

        dtrtrs('L', 'N', 'N', &p, &n, &temp_pp[0,0], &p, &temp_pn[0,0], &p, &info)
        if (&sigma_x[0,0] != &sigma_cond[0,0]):
            dcopy(&nn, &sigma_x[0,0], &inc, &sigma_cond[0,0], &inc)
        # TODO this call aliases pointers, should really call dsyrk and copy lower to upper
        dgemm('T', 'N', &n, &n, &p, &neg1, &temp_pn[0,0], &p, &temp_pn[0,0], &p, &one, &sigma_cond[0,0], &n)

        ll -= p/2. * log(2.*PI)
        for i in range(p):
            ll -= log(temp_pp[i,i])
        return ll


cdef inline void predict(
    # inputs
    double[:] mu, double[:,:] sigma,
    double[:,:] A, double[:,:] sigma_states,
    # outputs
    double[:] mu_predict, double[:,:] sigma_predict,
    # temps
    double[:,:] temp_nn,
    ) nogil:
    cdef int n = mu.shape[0]
    cdef int nn = n*n
    cdef int inc = 1
    cdef double one = 1., zero = 0.

    # NOTE: the A arguments are treated as transposed because A is assumed to be
    # in C order

    dgemv('T', &n, &n, &one, &A[0,0], &n, &mu[0], &inc, &zero, &mu_predict[0], &inc)

    dgemm('T', 'N', &n, &n, &n, &one, &A[0,0], &n, &sigma[0,0], &n, &zero, &temp_nn[0,0], &n)
    dcopy(&nn, &sigma_states[0,0], &inc, &sigma_predict[0,0], &inc)
    dgemm('N', 'N', &n, &n, &n, &one, &temp_nn[0,0], &n, &A[0,0], &n, &one, &sigma_predict[0,0], &n)


cdef inline void sample_gaussian(
    # inputs (which get mutated)
    double[:] mu, double[:,:] sigma,
    # input/output
    double[:] randvec,
    ) nogil:
    cdef int n = mu.shape[0]
    cdef int inc = 1, info = 0
    cdef double one = 1.

    dpotrf('L', &n, &sigma[0,0], &n, &info)
    dtrmv('L', 'N', 'N', &n, &sigma[0,0], &n, &randvec[0], &inc)
    daxpy(&n, &one, &mu[0], &inc, &randvec[0], &inc)


cdef inline void rts_backward_step(
    double[:,:] A, double[:,:] sigma_states,
    double[:] filtered_mu, double[:,:] filtered_sigma,  # inputs/outputs
    double[:] next_predict_mu, double[:,:] next_predict_sigma,  # mutated inputs!
    double[:] next_smoothed_mu, double[:,:] next_smoothed_sigma,
    double[:,:] temp_nn, double[:,:] temp_nn2,  # temps
    ) nogil:

    # NOTE: on exit, temp_nn holds the RTS gain, called G_k' in the notation of
    # Thm 8.2 of Sarkka 2013 "Bayesian Filtering and Smoothing"

    cdef int n = A.shape[0]
    cdef int nn = n*n
    cdef int inc = 1, info = 0
    cdef double one = 1., zero = 0., neg1 = -1.

    # NOTE: the A argument is treated as transposed because A is assumd to be in C order
    dgemm('T', 'N', &n, &n, &n, &one, &A[0,0], &n, &filtered_sigma[0,0], &n, &zero, &temp_nn[0,0], &n)
    # TODO: could just call dposv directly instead of dpotrf+dpotrs
    dcopy(&nn, &next_predict_sigma[0,0], &inc, &temp_nn2[0,0], &inc)
    dpotrf('L', &n, &temp_nn2[0,0], &n, &info)
    dpotrs('L', &n, &n, &temp_nn2[0,0], &n, &temp_nn[0,0], &n, &info)

    daxpy(&n, &neg1, &next_smoothed_mu[0], &inc, &next_predict_mu[0], &inc)
    dgemv('T', &n, &n, &neg1, &temp_nn[0,0], &n, &next_predict_mu[0], &inc, &one, &filtered_mu[0], &inc)

    daxpy(&nn, &neg1, &next_smoothed_sigma[0,0], &inc, &next_predict_sigma[0,0], &inc)
    dgemm('N', 'N', &n, &n, &n, &neg1, &next_predict_sigma[0,0], &n, &temp_nn[0,0], &n, &zero, &temp_nn2[0,0], &n)
    dgemm('T', 'N', &n, &n, &n, &one, &temp_nn[0,0], &n, &temp_nn2[0,0], &n, &one, &filtered_sigma[0,0], &n)


cdef inline void set_dynamics_stats(
    double[::1] mk, double[::1] mkn, double[:,::1] Pkns,
    double[::1,:] GkT,
    double[:,::1] ExxnT,
    ) nogil:

    cdef int n = mk.shape[0], inc = 1
    cdef double one = 1., zero = 0.
    dgemm('T', 'N', &n, &n, &n, &one, &GkT[0,0], &n, &Pkns[0,0], &n, &zero, &ExxnT[0,0], &n)
    dger(&n, &n, &one, &mk[0], &inc, &mkn[0], &inc, &ExxnT[0,0], &n)
