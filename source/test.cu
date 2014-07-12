#include <stdio.h>
#include <cublas_v2.h>
#include <util.cuh>
#include <basicOps.cuh>
#include <mpi.h>
#include <cuda.h>
#include <assert.h>
#include <util.cuh>
#include <clusterNet.h>
#include <time.h>
#include <batchAllocator.h>
#include <DeepNeuralNetwork.h>
#include <WikiMaxoutNet.h>

using std::cout;
using std::endl;





void run_neural_network()
{
  Matrix *X = read_hdf5("/home/tim/mnist_full_X.hdf5");
  Matrix *y = read_hdf5("/home/tim/mnist_full_y.hdf5");

  ClusterNet gpu = ClusterNet(12345);

  cout << X->rows << endl;

  int hidden_size = 1024;


  Matrix *w1 = gpu.sparseInitWeight(784,hidden_size);
  Matrix *w2 = gpu.sparseInitWeight(hidden_size,10);
  Matrix *m1 = zeros(784,hidden_size);
  Matrix *m2 = zeros(hidden_size,10);
  Matrix *ms1 = zeros(784,hidden_size);
  Matrix *ms2 = zeros(hidden_size,10);
  Matrix *grad_w1_ms = zeros(784,hidden_size);
  Matrix *grad_w2_ms = zeros(hidden_size,10);
  Matrix *grad_w2 = empty(hidden_size,10);
  Matrix *grad_w1 = empty(784,hidden_size);
  float cv_error = 0;
  float cv_size = 0.1428571f;
  float train_error = 0.0f;

  BatchAllocator b = BatchAllocator();
  b.init(X, y,  cv_size, 128, 512);

  clock_t t1,t2;
  t1=clock();
  //code goes here
  int epochs  = 100;
  gpu.tick();
  float learning_rate = 0.003;
  //size_t free = 0;
  //size_t total = 0;
  float momentum = 0.5;
  for(int EPOCH = 0; EPOCH < epochs; EPOCH++)
  {
	  std::cout << "EPOCH: " << EPOCH + 1 << std::endl;
	  //cudaMemGetInfo(&free, &total);
	  //std::cout << free << std::endl;
	  momentum += 0.01;
	  if(momentum > 0.95) momentum = 0.95;
	  for(int i = 0; i < b.TOTAL_BATCHES; i++)
	  {

		  b.allocate_next_batch_async();

		  //nesterov updates
		  scalarMul(m1,momentum,m1);
		  scalarMul(m2,momentum,m2);
		  add(w1,m1,w1);
		  add(w2,m2,w2);

		  Matrix *d0 = gpu.dropout(b.CURRENT_BATCH,0.2);
		  Matrix *z1 = gpu.dot(d0, w1);
		  logistic(z1, z1);
		  Matrix *d1 = gpu.dropout(z1,0.5);
		  Matrix *a2 = gpu.dot(d1,w2);
		  Matrix *out = softmax(a2);
		  Matrix *t = create_t_matrix(b.CURRENT_BATCH_Y,10);

		  //backprop
		  Matrix *e1 = sub(out, t);
		  Matrix *e2 = gpu.dotT(e1, w2);
		  gpu.Tdot(z1,e1,grad_w2);
		  logisticGrad(z1,z1);
		  mul(e2,z1,e2);
		  gpu.Tdot(b.CURRENT_BATCH,e2,grad_w1);

		  b.allocate_next_batch_async();

		  RMSprop_with_momentum_weight_update(ms1,grad_w1,w1,m1,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);
		  RMSprop_with_momentum_weight_update(ms2,grad_w2,w2,m2,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);

		  cudaFree(e1->data);
		  cudaFree(e2->data);
		  cudaFree(z1->data);
		  cudaFree(a2->data);
		  cudaFree(out->data);
		  cudaFree(t->data);
		  cudaFree(d0->data);
		  cudaFree(d1->data);

		  b.replace_current_batch_with_next();

	  }


	  //Matrix *sum_value = sum(w1);
	  //std::cout << "weight 1 Sum: " << to_host(sum_value)->data[0] << std::endl;

	  train_error = 0;
	  for(int i = 0; i < b.TOTAL_BATCHES; i++)
	  {

		  b.broadcast_batch_to_processes();

		  //Matrix *d0 = scalarMul(b.CURRENT_BATCH,0.8);
		  Matrix *a1 = gpu.dot(b.CURRENT_BATCH,w1);
		  logistic(a1, a1);
		  //Matrix *d1 = scalarMul(a1,0.5);
		  Matrix *a2 = gpu.dot(a1,w2);
		  Matrix *out = softmax(a2);
		  Matrix *result = argmax(out);
		  Matrix *eq = equal(result,b.CURRENT_BATCH_Y);
		  b.allocate_next_batch_async();
		  float sum_value = sum(eq);

		  train_error += (b.CURRENT_BATCH->rows - sum_value)/ (1.0f * b.CURRENT_BATCH->rows *b.TOTAL_BATCHES) ;

		  cudaFree(a1->data);
		  cudaFree(a2->data);
		  cudaFree(out->data);
		  cudaFree(result->data);
		  cudaFree(eq->data);
		  //cudaFree(d0->data);
		  //cudaFree(d1->data);

		  b.replace_current_batch_with_next();
	  }


	  std::cout << "Train error: " << train_error << std::endl;


	  cv_error = 0;
	  for(int i = 0; i < b.TOTAL_BATCHES_CV; i++)
	  {
		  b.broadcast_batch_cv_to_processes();
		  Matrix *d0 = scalarMul(b.CURRENT_BATCH_CV,0.8);
		  Matrix *a1 = gpu.dot(d0,w1);
		  logistic(a1, a1);
		  Matrix *d1 = scalarMul(a1,0.5);
		  Matrix *a2 = gpu.dot(d1,w2);
		  Matrix *out = softmax(a2);
		  Matrix *result = argmax(out);
		  Matrix *eq = equal(result,b.CURRENT_BATCH_CV_Y);
		  b.allocate_next_cv_batch_async();
		  float sum_value = sum(eq);

		  cv_error += (b.CURRENT_BATCH_CV->rows  - sum_value)/ (1.0f * b.CURRENT_BATCH_CV->rows *b.TOTAL_BATCHES_CV) ;

		  cudaFree(a1->data);
		  cudaFree(a2->data);
		  cudaFree(out->data);
		  cudaFree(result->data);
		  cudaFree(eq->data);
		  cudaFree(d0->data);
		  cudaFree(d1->data);

		  b.replace_current_cv_batch_with_next();
	  }

	  std::cout << "Cross validation error: " << cv_error << std::endl;


  }

  cudaThreadSynchronize();
  t2=clock();
  float diff ((float)t2-(float)t1);
  float mseconds = (diff / CLOCKS_PER_SEC)/1000;
  std::cout<<mseconds<<std::endl;
  gpu.tock();

  b.finish_batch_allocator();

  //gpu.tock("batch replace");
  //gpu.tock("async batch allocate");
  //gpu.tock("feedforward");


  printf("Finished!\n");
}


void run_maxout_network()
{

	cudaSetDevice(0);
    Matrix *X = read_hdf5("/home/tim/mnist_full_X.hdf5");
    Matrix *y = read_hdf5("/home/tim/mnist_full_y.hdf5");

  	ClusterNet gpus = ClusterNet(12345);

  	int hiddenunits = 512;
  	int maxout_Size = 8;
  	int batch_size = 128;

	Matrix *w1 = gpus.uniformSqrtWeight(784,hiddenunits);
	Matrix *w2 = gpus.uniformSqrtWeight(hiddenunits/maxout_Size,10);
	Matrix *b1 = zeros(1,hiddenunits);
	Matrix *b2 = zeros(1,10);
	Matrix *m1 = zeros(784,hiddenunits);
	Matrix *m2 = zeros(hiddenunits/maxout_Size,10);
	Matrix *mb1 = zeros(1,hiddenunits);
	Matrix *mb2 = zeros(1,10);
	Matrix *ms1 = zeros(784,hiddenunits);
	Matrix *ms2 = zeros(hiddenunits/maxout_Size,10);
	Matrix *msb1 = zeros(1,hiddenunits);
	Matrix *msb2 = zeros(1,10);
	Matrix *grad_w1 = zeros(784,hiddenunits);
	Matrix *grad_w2 = zeros(hiddenunits/maxout_Size,10);
	Matrix *grad_b1 = zeros(1,hiddenunits);
	Matrix *grad_b2 = zeros(1,10);


	float cv_error = 0.0f;
	float train_error = 0.0f;

	BatchAllocator b = BatchAllocator();
	b.init(X, y, 0.2, batch_size, 512);
	int epochs  = 1000;
	float learning_rate = 0.001;
	float momentum = 0.5;
	for(int EPOCH = 1; EPOCH < epochs; EPOCH++)
	{
	  cout << "EPOCH: " << EPOCH << endl;
	  //momentum += 0.01;
	  //if(momentum > 0.95) momentum = 0.95;
	  for(int i = 0; i < b.TOTAL_BATCHES; i++)
	  {
		  b.broadcast_batch_to_processes();

		  //nesterov updates
		  scalarMul(m1,momentum,m1);
		  scalarMul(m2,momentum,m2);
		  scalarMul(mb1,momentum,mb1);
		  scalarMul(mb2,momentum,mb2);
		  add(w1,m1,w1);
		  add(w2,m2,w2);
		  add(b1,mb1,b1);
		  add(b2,mb2,b2);


		  //feedforward
		  Matrix *d0 = gpus.dropout(b.CURRENT_BATCH,0.2);
		  Matrix *z1 = gpus.dot(d0, w1);
		  addMatrixVector(z1,b1,z1);
		  Matrix **a_paired = maxout(z1,maxout_Size);
		  Matrix *a1 = a_paired[0];
		  Matrix *a1_idx = a_paired[1];
		  Matrix *d1 = gpus.dropout(a1,0.5);
		  Matrix *a2 = gpus.dot(d1,w2);
		  addMatrixVector(a2,b2,a2);
		  Matrix *out = softmax(a2);
		  Matrix *t = create_t_matrix(b.CURRENT_BATCH_Y,10);

		  b.allocate_next_batch_async();

		  //backprop
		  Matrix *e1 = sub(out, t);
		  Matrix *e2_partial = gpus.dotT(e1, w2);
		  Matrix *e2 = empty(b.CURRENT_BATCH->rows,e2_partial->cols*maxout_Size);
		  Matrix *aB = ones(1,b.CURRENT_BATCH->rows);


		  gpus.Tdot(a1,e1,grad_w2);
		  gpus.dot(aB,e1,grad_b2);
		  expand_to_maxout_grad(e2_partial, a1_idx,e2);
		  gpus.Tdot(b.CURRENT_BATCH,e2,grad_w1);
		  gpus.dot(aB,e2,grad_b1);

		  //weight updates
		  //RMSProp


		  RMSprop_with_momentum_weight_update(ms1,grad_w1,w1,m1,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);
		  RMSprop_with_momentum_weight_update(ms2,grad_w2,w2,m2,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);

		  RMSprop_with_momentum_weight_update(msb1,grad_b1,b1,mb1,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);
		  RMSprop_with_momentum_weight_update(msb2,grad_b2,b2,mb2,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);



/*
		  scalarMul(grad_w1,learning_rate/(float)b.CURRENT_BATCH->rows,grad_w1);
		  scalarMul(grad_w2,learning_rate/(float)b.CURRENT_BATCH->rows,grad_w2);
		  scalarMul(grad_b1,learning_rate/(float)b.CURRENT_BATCH->rows,grad_b1);
		  scalarMul(grad_b2,learning_rate/(float)b.CURRENT_BATCH->rows,grad_b2);



		  //classical momentum
		  scalarMul(m1,momentum,m1);
		  scalarMul(m2,momentum,m2);
		  scalarMul(mb1,momentum,mb1);
		  scalarMul(mb2,momentum,mb2);
		  sub(m1,grad_w1,m1);
		  sub(m2,grad_w2,m2);
		  sub(mb1,grad_b1,mb1);
		  sub(mb2,grad_b2,mb2);

		  add(w1,m1,w1);
		  add(w2,m2,w2);
		  add(b1,mb1,b1);
		  add(b2,mb2,b2);

		  */



		  /*
		  sub(w1,grad_w1,w1);
		  sub(w2,grad_w2,w2);
		  sub(b1,grad_b1,b1);
		  sub(b2,grad_b2,b2);
		  */



		  cudaFree(e1->data);
		  cudaFree(e2->data);
		  cudaFree(e2_partial->data);
		  cudaFree(z1->data);
		  cudaFree(a1->data);
		  cudaFree(a1_idx->data);
		  cudaFree(a2->data);
		  cudaFree(out->data);
		  cudaFree(t->data);
		  cudaFree(d0->data);
		  cudaFree(d1->data);
		  cudaFree(aB->data);
		  free(a_paired);

		  b.replace_current_batch_with_next();

	  }



	  train_error = 0;
	  for(int i = 0; i < b.TOTAL_BATCHES; i++)
	  {

		  b.broadcast_batch_to_processes();

		  Matrix *d0 = scalarMul(b.CURRENT_BATCH,0.8);
		  Matrix *z1 = gpus.dot(d0,w1);
		  Matrix **a1_pair = maxout(z1,maxout_Size);
		  Matrix *a1 = a1_pair[0];
		  Matrix *d1 = scalarMul(a1,0.5);
		  Matrix *a2 = gpus.dot(d1,w2);
		  Matrix *out = softmax(a2);
		  Matrix *result = argmax(out);
		  Matrix *eq = equal(result,b.CURRENT_BATCH_Y);
		  b.allocate_next_batch_async();
		  float sum_value = sum(eq);

		  train_error += (b.CURRENT_BATCH->rows - sum_value)/ (1.0f * b.CURRENT_BATCH->rows *b.TOTAL_BATCHES) ;

		  cudaFree(z1->data);
		  cudaFree(a1->data);
		  cudaFree(a1_pair[1]->data);
		  cudaFree(a2->data);
		  cudaFree(out->data);
		  cudaFree(result->data);
		  cudaFree(eq->data);
		  cudaFree(d0->data);
		  cudaFree(d1->data);
		  free(a1_pair);

		  b.replace_current_batch_with_next();
	  }

	  std::cout << "MAXOUT Train error: " << train_error << std::endl;



	  cv_error = 0;
	  for(int i = 0; i < b.TOTAL_BATCHES_CV; i++)
	  {
		  b.broadcast_batch_cv_to_processes();
		  Matrix *d0 = scalarMul(b.CURRENT_BATCH_CV,0.8);
		  Matrix *z1 = gpus.dot(d0,w1);
		  Matrix **a1_pair = maxout(z1,maxout_Size);
		  Matrix *a1 = a1_pair[0];
		  Matrix *d1 = scalarMul(a1,0.5);
		  Matrix *a2 = gpus.dot(d1,w2);
		  Matrix *out = softmax(a2);
		  Matrix *result = argmax(out);
		  Matrix *eq = equal(result,b.CURRENT_BATCH_CV_Y);
		  b.allocate_next_batch_async();
		  float sum_value = sum(eq);

		  cv_error += (b.CURRENT_BATCH_CV->rows  - sum_value)/ (1.0f * b.CURRENT_BATCH_CV->rows *b.TOTAL_BATCHES_CV) ;

		  cudaFree(z1->data);
		  cudaFree(a1->data);
		  cudaFree(a1_pair[1]->data);
		  cudaFree(a2->data);
		  cudaFree(out->data);
		  cudaFree(result->data);
		  cudaFree(eq->data);
		  cudaFree(d0->data);
		  cudaFree(d1->data);
		  free(a1_pair);

		  b.replace_current_cv_batch_with_next();
	  }

	  std::cout << "MAXOUT Cross validation error: " << cv_error << std::endl;

	}

}


void run_normal_net()
{
	cudaSetDevice(2);
    Matrix *X = read_hdf5("/home/tim/mnist_full_X.hdf5");
    Matrix *y = read_hdf5("/home/tim/mnist_full_y.hdf5");

  	ClusterNet gpus = ClusterNet(12345);

  	int hiddenunits = 1024;
  	int maxout_Size = 1;
  	int batch_size = 128;

	Matrix *w1 = gpus.uniformSqrtWeight(784,hiddenunits);
	Matrix *w2 = gpus.uniformSqrtWeight(hiddenunits/maxout_Size,10);
	Matrix *b1 = zeros(1,hiddenunits);
	Matrix *b2 = zeros(1,10);
	Matrix *m1 = zeros(784,hiddenunits);
	Matrix *m2 = zeros(hiddenunits/maxout_Size,10);
	Matrix *mb1 = zeros(1,hiddenunits);
	Matrix *mb2 = zeros(1,10);
	Matrix *ms1 = zeros(784,hiddenunits);
	Matrix *ms2 = zeros(hiddenunits/maxout_Size,10);
	Matrix *msb1 = zeros(1,hiddenunits);
	Matrix *msb2 = zeros(1,10);
	Matrix *grad_w1 = zeros(784,hiddenunits);
	Matrix *grad_w2 = zeros(hiddenunits/maxout_Size,10);
	Matrix *grad_b1 = zeros(1,hiddenunits);
	Matrix *grad_b2 = zeros(1,10);


	float cv_error = 0.0f;
	float train_error = 0.0f;

	BatchAllocator b = BatchAllocator();
	b.init(X, y, 0.4, batch_size, 512);
	int epochs  = 500;
	float learning_rate = 0.000001;
	float momentum = 0.5;
	for(int EPOCH = 1; EPOCH < epochs; EPOCH++)
	{
	  cout << "EPOCH: " << EPOCH << endl;
	  momentum += 0.01;
	  if(momentum > 0.95) momentum = 0.95;
	  for(int i = 0; i < b.TOTAL_BATCHES; i++)
	  {
		  b.broadcast_batch_to_processes();

		  //nesterov updates
		  scalarMul(m1,momentum,m1);
		  scalarMul(m2,momentum,m2);
		  scalarMul(mb1,momentum,mb1);
		  scalarMul(mb2,momentum,mb2);
		  add(w1,m1,w1);
		  add(w2,m2,w2);
		  add(b1,mb1,b1);
		  add(b2,mb2,b2);







		  //feedforward
		  Matrix *d0 = gpus.dropout(b.CURRENT_BATCH,0.2);
		  Matrix *z1 = gpus.dot(d0, w1);
		  addMatrixVector(z1,b1,z1);
		  Matrix *a1 = logistic(z1);
		  //Matrix *a1 = rectified_linear(z1);
		  Matrix *d1 = gpus.dropout(a1,0.5);
		  Matrix *a2 = gpus.dot(d1,w2);
		  addMatrixVector(a2,b2,a2);
		  Matrix *out = softmax(a2);
		  Matrix *t = create_t_matrix(b.CURRENT_BATCH_Y,10);

		  b.allocate_next_batch_async();

		  //backprop
		  Matrix *e1 = sub(out, t);
		  Matrix *e2 = gpus.dotT(e1, w2);
		  Matrix *aB = ones(1,b.CURRENT_BATCH->rows);


		  gpus.Tdot(a1,e1,grad_w2);
		  gpus.dot(aB,e1,grad_b2);
		  //rectified_linear_derivative(a1,a1);
		  logisticGrad(a1,a1);
		  mul(e2,a1,e2);
		  gpus.Tdot(b.CURRENT_BATCH,e2,grad_w1);
		  gpus.dot(aB,e2,grad_b1);



		  /*
		  //about equal to momentum update + nesterov update -> momentum applyied to gradient+momentum better?
		  RMSprop_with_momentum_weight_update(ms1,grad_w1,w1,m1,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);
		  RMSprop_with_momentum_weight_update(ms2,grad_w2,w2,m2,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);

		  RMSprop_with_momentum_weight_update(msb1,grad_b1,b1,mb1,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);
		  RMSprop_with_momentum_weight_update(msb2,grad_b2,b2,mb2,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);
		  */

		  /*
		  //slow and generally worse error, but sometimes better results in the end
		  RMSprop_with_momentum_update(ms1,grad_w1,w1,m1,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);
		  RMSprop_with_momentum_update(ms2,grad_w2,w2,m2,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);

		  RMSprop_with_momentum_update(msb1,grad_b1,b1,mb1,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);
		  RMSprop_with_momentum_update(msb2,grad_b2,b2,mb2,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);
		  */




		  RMSprop_with_nesterov_weight_update(ms1,grad_w1,w1,m1,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);
		  RMSprop_with_nesterov_weight_update(ms2,grad_w2,w2,m2,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);

		  RMSprop_with_nesterov_weight_update(msb1,grad_b1,b1,mb1,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);
		  RMSprop_with_nesterov_weight_update(msb2,grad_b2,b2,mb2,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);


		  /*
		  //slower but equally good to nesterov momentum
		  RMSprop_with_weight_update(ms1,grad_w1,w1,m1,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);
		  RMSprop_with_weight_update(ms2,grad_w2,w2,m2,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);

		  RMSprop_with_weight_update(msb1,grad_b1,b1,mb1,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);
		  RMSprop_with_weight_update(msb2,grad_b2,b2,mb2,0.9f,learning_rate,b.CURRENT_BATCH->rows, momentum);
		  */
		  /*





		  scalarMul(grad_w1,learning_rate/(float)b.CURRENT_BATCH->rows,grad_w1);
		  scalarMul(grad_w2,learning_rate/(float)b.CURRENT_BATCH->rows,grad_w2);
		  scalarMul(grad_b1,learning_rate/(float)b.CURRENT_BATCH->rows,grad_b1);
		  scalarMul(grad_b2,learning_rate/(float)b.CURRENT_BATCH->rows,grad_b2);



		  //classical momentum
		  scalarMul(m1,momentum,m1);
		  scalarMul(m2,momentum,m2);
		  scalarMul(mb1,momentum,mb1);
		  scalarMul(mb2,momentum,mb2);
		  sub(m1,grad_w1,m1);
		  sub(m2,grad_w2,m2);
		  sub(mb1,grad_b1,mb1);
		  sub(mb2,grad_b2,mb2);


		  add(w1,m1,w1);
		  add(w2,m2,w2);
		  add(b1,mb1,b1);
		  add(b2,mb2,b2);
		  */




		  /*
		  sub(w1,grad_w1,w1);
		  sub(w2,grad_w2,w2);
		  sub(b1,grad_b1,b1);
		  sub(b2,grad_b2,b2);
		  */



		  cudaFree(e1->data);
		  cudaFree(e2->data);
		  cudaFree(z1->data);
		  cudaFree(a1->data);
		  cudaFree(a2->data);
		  cudaFree(out->data);
		  cudaFree(t->data);
		  cudaFree(d0->data);
		  cudaFree(d1->data);
		  cudaFree(aB->data);

		  b.replace_current_batch_with_next();

	  }



	  train_error = 0;
	  for(int i = 0; i < b.TOTAL_BATCHES; i++)
	  {

		  b.broadcast_batch_to_processes();

		  Matrix *d0 = scalarMul(b.CURRENT_BATCH,0.8);
		  Matrix *z1 = gpus.dot(d0,w1);
		  Matrix *a1 = logistic(z1);
		  //Matrix *a1 = rectified_linear(z1);
		  Matrix *d1 = scalarMul(a1,0.5);
		  Matrix *a2 = gpus.dot(d1,w2);
		  Matrix *out = softmax(a2);
		  Matrix *result = argmax(out);
		  Matrix *eq = equal(result,b.CURRENT_BATCH_Y);
		  b.allocate_next_batch_async();
		  float sum_value = sum(eq);

		  train_error += (b.CURRENT_BATCH->rows - sum_value)/ (1.0f * b.CURRENT_BATCH->rows *b.TOTAL_BATCHES) ;

		  cudaFree(z1->data);
		  cudaFree(a1->data);
		  cudaFree(a2->data);
		  cudaFree(out->data);
		  cudaFree(result->data);
		  cudaFree(eq->data);
		  cudaFree(d0->data);
		  cudaFree(d1->data);

		  b.replace_current_batch_with_next();
	  }

	  std::cout << "MAXOUT Train error: " << train_error << std::endl;



	  cv_error = 0;
	  for(int i = 0; i < b.TOTAL_BATCHES_CV; i++)
	  {
		  b.broadcast_batch_cv_to_processes();
		  Matrix *d0 = scalarMul(b.CURRENT_BATCH_CV,0.8);
		  Matrix *z1 = gpus.dot(d0,w1);
		  Matrix *a1 = logistic(z1);
		  //Matrix *a1 = rectified_linear(z1);
		  Matrix *d1 = scalarMul(a1,0.5);
		  Matrix *a2 = gpus.dot(d1,w2);
		  Matrix *out = softmax(a2);
		  Matrix *result = argmax(out);
		  Matrix *eq = equal(result,b.CURRENT_BATCH_CV_Y);
		  b.allocate_next_batch_async();
		  float sum_value = sum(eq);

		  cv_error += (b.CURRENT_BATCH_CV->rows  - sum_value)/ (1.0f * b.CURRENT_BATCH_CV->rows *b.TOTAL_BATCHES_CV) ;

		  cudaFree(z1->data);
		  cudaFree(a1->data);
		  cudaFree(a2->data);
		  cudaFree(out->data);
		  cudaFree(result->data);
		  cudaFree(eq->data);
		  cudaFree(d0->data);
		  cudaFree(d1->data);

		  b.replace_current_cv_batch_with_next();
	  }

	  std::cout << "MAXOUT Cross validation error: " << cv_error << std::endl;

	}

}

void MPI_benchmark_P2P(int argc, char *argv[])
{
	char name[100];
    int myrank, length, size;
    MPI_Init(&argc, &argv);
    MPI_Comm_rank(MPI_COMM_WORLD, &myrank);
    MPI_Get_processor_name(name, &length);
	MPI_Comm_size(MPI_COMM_WORLD, &size);
	MPI_Status status;

	int local_rank = myrank % 4;

	int gpus;
	cudaGetDeviceCount(&gpus);
	int mygpu_id;
	int your_gpu_id;
	if(myrank == 0)
	{
		mygpu_id = 0;
		if(gpus > 1)
			your_gpu_id = 1;
		else
			your_gpu_id = 0;

		MPI_Send(&your_gpu_id,1, MPI_INT,1,0,MPI_COMM_WORLD);
	}
	else
	{
		MPI_Recv(&mygpu_id,1,MPI_INT,myrank-1,0,MPI_COMM_WORLD,&status);
		if(gpus > mygpu_id+1)
			your_gpu_id = mygpu_id + 1;
		else
			your_gpu_id = 0;
		if(myrank < size-1)
			MPI_Send(&your_gpu_id,1, MPI_INT,myrank+1,0,MPI_COMM_WORLD);
	}

	cudaSetDevice(mygpu_id);


		int batch_size = 128;
		int inner_dim = 10000;
		int outer_dim = 15000;

		ClusterNet gpu = ClusterNet();
		Matrix *A = gpu.rand(batch_size,inner_dim);
		Matrix *B = gpu.rand(inner_dim,outer_dim);
		Matrix *out = empty(batch_size,outer_dim);
		Matrix *rec = empty(batch_size,outer_dim);

		Matrix *A1 = gpu.rand(batch_size/2,inner_dim);
		Matrix *B1 = gpu.rand(inner_dim,outer_dim);
		Matrix *rec1 = empty(batch_size/2,outer_dim);
		Matrix *out1 = empty(batch_size/2,outer_dim);

		Matrix *A2 = gpu.rand(batch_size,inner_dim);
		Matrix *B2 = gpu.rand(inner_dim,outer_dim/2);
		Matrix *rec2 = empty(batch_size,outer_dim/2);
		Matrix *out2 = empty(batch_size,outer_dim/2);


		gpu.tick("Direct compute");
	    for(int i = 0; i< 100; i++)
	    {
	      gpu.dot(A,B, out);
		//add(A, B, out);
	    }
	    gpu.tock("Direct compute");

		gpu.tick("partial batch direct compute");
	    for(int i = 0; i< 100; i++)
	    {
	      gpu.dot(A1,B1, out1);
		//add(A, B, out);
	    }
	    gpu.tock("partial batch direct compute");

		gpu.tick("partial units direct compute");
	    for(int i = 0; i< 100; i++)
	    {
	      gpu.dot(A2,B2, out2);
		//add(A, B, out);
	    }
	    gpu.tock("partial units direct compute");




		gpu.tick("PCIe transfer");
		for(int i = 0; i< 100; i++)
		{
			if(local_rank == 0 && gpus > 1)
			{
				MPI_Send(out->data, out->size, MPI_FLOAT, 1, 100, MPI_COMM_WORLD);
			}
			else if(local_rank == 1 && gpus > 1)
			{
				//add(A2,B, out);
				MPI_Recv(rec->data, rec->size, MPI_FLOAT, 0, 100, MPI_COMM_WORLD, &status);
			}
		}
		gpu.tock("PCIe transfer");


		gpu.tick("PCIe dot");
		for(int i = 0; i< 100; i++)
		{
			if(local_rank == 0 && gpus > 1)
			{
				gpu.dot(A2,B2,out2);
				MPI_Send(out1->data, out1->size, MPI_FLOAT, 1, 100, MPI_COMM_WORLD);
			}
			else if(local_rank == 1 && gpus > 1)
			{
				gpu.dot(A2,B2,out2);
				MPI_Recv(rec1->data, rec1->size, MPI_FLOAT, 0, 100, MPI_COMM_WORLD, &status);
				vStack(out2,rec2,rec);
			}
		}
		gpu.tock("PCIe dot");



		gpu.tick("RDMA transfer");
		for(int i = 0; i< 100; i++)
		{
			if(myrank == 0)
			{
				MPI_Send(out->data, out->size, MPI_FLOAT, 3, 100, MPI_COMM_WORLD);
			}
			else if(myrank == 3)
			{
				//add(A2,B, out);
				MPI_Recv(rec->data, rec->size, MPI_FLOAT, 0, 100, MPI_COMM_WORLD, &status);
			}
		}
		gpu.tock("RDMA transfer");


		gpu.tick("RDMA dot");
		for(int i = 0; i< 100; i++)
		{
			if(myrank == 0)
			{
				gpu.dot(A2,B2,out2);
				MPI_Send(out->data, out->size, MPI_FLOAT, 3, 100, MPI_COMM_WORLD);
			}
			else if(myrank == 3)
			{
				//add(A2,B, out);
				gpu.dot(A2,B2,out2);
				MPI_Recv(rec->data, rec->size, MPI_FLOAT, 0, 100, MPI_COMM_WORLD, &status);
				vStack(out2,rec2,rec);
			}
		}
		gpu.tock("RDMA dot");








	MPI_Finalize();



}


void MPI_benchmark(int argc, char *argv[])
{
    int myrank;
    MPI_Status status;
    MPI_Init(&argc, &argv);
    MPI_Comm_rank(MPI_COMM_WORLD, &myrank);

    ClusterNet gpu = ClusterNet();
    int batch_rows = 128;
    int w_in = 10000;
    int w_out = 8000;

    //dot
    Matrix *B = gpu.rand(w_in,w_out);
    Matrix *A = gpu.rand(batch_rows,w_in);
    assert(test_matrix(A,batch_rows,w_in));
    assert(test_matrix(B,w_in,w_out));
    Matrix *out = empty(batch_rows, w_out);

    Matrix *B1 = gpu.rand(w_in,w_out/2);
    Matrix *B2 = gpu.rand(w_in,w_out/2);
    Matrix *D = empty(batch_rows,w_out/2);
    Matrix *A1 = gpu.rand(batch_rows/2,w_in);
    Matrix *big_out = gpu.rand(batch_rows/2,w_out);
    Matrix *grand_out = empty(batch_rows, w_out);

    Matrix *C = gpu.rand(batch_rows/2,w_in);
    Matrix *C_out = empty(batch_rows/2,w_out);

    Matrix *E = gpu.rand(batch_rows/4,w_in);
    Matrix *E_out = empty(batch_rows/4,w_out);
    Matrix *E_merge = empty(batch_rows/2,w_out);
    Matrix *E_merge2 = empty(batch_rows/2,w_out);

    //add

    /*
    B = gpu.rand(w_in,w_out);
    A = gpu.rand(w_in,w_out);
    out = empty(w_in, w_out);
    A1 = gpu.rand(w_in/2,w_out);
    Matrix *A2 = gpu.rand(w_in/2,w_out);
    D = empty(w_in/2,w_out);
*/

    cudaEvent_t* startstop = tick();
    for(int i = 0; i< 100; i++)
    {
      gpu.dot(A,B, out);
	//add(A, B, out);
    }
    printf("Direct compute:\n");
    tock(startstop);


    out = empty(batch_rows,w_out/2);
    Matrix *out2 = empty(batch_rows,w_out/2);
    startstop = tick();
    for(int i = 0; i< 100; i++)
    {
      gpu.dot(A,B1, out);
      gpu.dot(A,B2, out2);
      vStack(out,out2,grand_out);
    }
    printf("Direct compute x2:\n");
    tock(startstop);

    Matrix *mergemat = empty(batch_rows, w_out);
    out = empty(batch_rows,w_out/2);
    startstop = tick();
    //out = empty(w_in/2,w_out);
    for(int i = 0; i < 100; i++)
    {
	    if(myrank == 0)
	    {
		gpu.dot(A,B1, out);
    		//add(A1, B,out);
		MPI_Send(out->data, out->size, MPI_FLOAT, 1, 100, MPI_COMM_WORLD);
	    }
	    else
	    {
		gpu.dot(A,B2, out);
		//add(A2,B, out);
	 	MPI_Recv(D->data, D->size, MPI_FLOAT, 0, 100, MPI_COMM_WORLD, &status);
                vStack(out,D, mergemat);
	    }

    }

    if(myrank == 1)
    {
      printf("GPUDirect RDMA:\n");
      tock(startstop);
    }

    out = empty(batch_rows/2,w_out);
    startstop = tick();
    gpu.tick("aa");
    //out = empty(w_in/2,w_out);
    for(int i = 0; i < 100; i++)
    {
    	gpu.tick("dot");
		gpu.dot(C,B, out);
		gpu.tick("dot");

	    if(myrank == 0)
	    {
    		//add(A1, B,out);
		gpu.tick("send");
		MPI_Send(out->data, out->size, MPI_FLOAT, 1, 100, MPI_COMM_WORLD);
		gpu.tick("send");
	    }
	    else
	    {
		//add(A2,B, out);
		gpu.tick("receive");
	 	MPI_Recv(C_out->data, C_out->size, MPI_FLOAT, 0, 100, MPI_COMM_WORLD, &status);
                vStack(out,C_out, grand_out);
                gpu.tick("receive");
	    }

	    if(myrank == 1)
	    {
    		//add(A1, B,out);
		gpu.tick("send");
		MPI_Send(out->data, out->size, MPI_FLOAT, 0, 100, MPI_COMM_WORLD);
		gpu.tick("send");
	    }
	    else
	    {
		//add(A2,B, out);
		gpu.tick("receive");
	 	MPI_Recv(C_out->data, C_out->size, MPI_FLOAT, 1, 100, MPI_COMM_WORLD, &status);
                vStack(out,C_out, grand_out);
                gpu.tick("receive");
	    }

    }

    gpu.tock("dot");

    if(myrank == 1)
    {
      printf("GPUDirect RDMA batch:\n");
      tock(startstop);

      gpu.tock("receive");
      gpu.tock("aa");
    }
    else
    {

        gpu.tock("send");
    }










    MPI_Finalize();

}



void dotMPI_test(int argc, char *argv[])
{

	/*
	ClusterNet gpu = ClusterNet(argc, argv, 123465);
	int inner = 2000;
	int outer = 1200;
	int batch_size = 128;


	int reduced_left = 128;
	int reduced_right = 400;
	Matrix *A = gpu.rand(batch_size,inner);
	Matrix *B = gpu.rand(inner,outer);
	Matrix *A1 = gpu.rand(reduced_left,inner);
	Matrix *B1 = gpu.rand(inner,reduced_right);

	Matrix *out = empty(batch_size,outer);
	Matrix *out1 = empty(reduced_left,reduced_right);
	Matrix *recv1 = empty(reduced_left,reduced_right);
	Matrix *recv2 = empty(reduced_left,reduced_right);
	Matrix *recv3 = empty(reduced_left,reduced_right);
	MPI_Status status;




	gpu.tick("dot mpi batch");
	for(int i = 0; i < 100; i++)
	{
		gpu.dotMPI_batchSlice(A,B);
	}
	gpu.tock("dot mpi batch");



	gpu.tick("dot mpi unit");
	for(int i = 0; i < 100; i++)
	{
		gpu.dotMPI_unitSlice(A,B);
	}
	gpu.tock("dot mpi unit");

	printf("My rank: %i\n",gpu.MYRANK);
	//gpu.benchmark_dot();



	gpu.tick("dot normal");
	for(int i = 0; i < 100; i++)
	{
		gpu.dot(A,B,out);
	}
	gpu.tock("dot normal");



	//std::vector<MPI_Request> requests;
	MPI_Request *requests = (MPI_Request*)malloc(sizeof(MPI_Request)*gpu.MPI_SIZE-1);
	MPI_Request request_send;
	std::vector<Matrix*> recv_buffer;
	for(int i = 0; i < gpu.MPI_SIZE-1; i++)
	{
		MPI_Request request;
		requests[i] = request;
	}




	int received_count = 0;
	for(int i = 0; i < 100; i++)
	{
		for(int i = 0; i < recv_buffer.size(); i++)
			cudaFree(recv_buffer[i]->data);
		recv_buffer.clear();
		out1 = empty(reduced_left,reduced_right);
		for(int i = 0; i < gpu.MPI_SIZE; i++)
		{
			recv_buffer.push_back(empty(reduced_left,reduced_right));
		}

		gpu.tick("all to all custom");
		//cout << "a1 rows" << A1->rows << endl;
		gpu.dot(A1,B1,out1);
		recv_buffer[gpu.MYRANK]= out1;
		for(int i = 0; i < gpu.MPI_SIZE; i++)
		{
			if(gpu.MYRANK == i) { continue; }
			MPI_Isend(out1->data, out1->size, MPI_FLOAT, i, 100, MPI_COMM_WORLD, &request_send);
		}

		for(int i = 0; i < gpu.MPI_SIZE; i++)
		{
			if(gpu.MYRANK == i) { continue; }
			MPI_Irecv(recv1->data, recv1->size, MPI_FLOAT, i, 100, MPI_COMM_WORLD, &requests[i]);

		}

		for(int i = 0; i < gpu.MPI_SIZE; i++)
		{
			if(gpu.MYRANK == i) { continue; }
			MPI_Wait(&requests[i],MPI_STATUS_IGNORE);
		}



		received_count = 0;
		while(received_count < gpu.MPI_SIZE-1)
		{
			for(int i = 0; i < gpu.MPI_SIZE; i++)
			{
				int received = 0;
				if(gpu.MYRANK == i) { continue; }
				MPI_Test(&requests[i],&received,&status);
				if(received == 1)
				{
					out1 = hStack(out1,recv1);
					received_count++;
				}
			}
		}

		gpu.tick("all to all custom");
	}
	gpu.tock("all to all custom");



	int destination = gpu.MYRANK + 1;
	int source = gpu.MYRANK - 1;
	if(destination == gpu.MPI_SIZE){destination = 0; }
	if(source < 0){ source = gpu.MPI_SIZE - 1;}
	for(int i = 0; i < 100; i++)
	{
		out1 = empty(reduced_left,reduced_right);
		recv1 = empty(reduced_left,reduced_right);
		gpu.tick("chain custom");
		gpu.dot(A1,B1,out1);
		for(int i = 0; i < gpu.MPI_SIZE-1; i++)
		{
			if(i == 0)
				MPI_Isend(out1->data, out1->size, MPI_FLOAT, destination, 100, MPI_COMM_WORLD, &request_send);
			else
				MPI_Isend(recv1->data, recv1->size, MPI_FLOAT, destination, 100, MPI_COMM_WORLD, &request_send);

			MPI_Recv(recv1->data, recv1->size, MPI_FLOAT, source, 100, MPI_COMM_WORLD, &status);

			//MPI_Wait(&requests[i],&status);
			out1 = hStack(out1,recv1);
		}
		gpu.tick("chain custom");
	}
	gpu.tock("chain custom");



	cout << gpu.MYRANK << endl;




	int matrix_idx = gpu.MYRANK;
	Matrix** arrOut = (Matrix**)malloc(sizeof(Matrix*)*gpu.MPI_SIZE);
	for(int i = 0; i < gpu.MPI_SIZE; i++)
		arrOut[i] = empty(reduced_left,reduced_right);

	float **h_arrA = (float**)malloc(sizeof(float*)*gpu.MPI_SIZE);
		for(int i = 0; i < gpu.MPI_SIZE; i++)
			h_arrA[i] = arrOut[i]->data;

	float **d_arrA;
	cudaMalloc((void**) &d_arrA,sizeof(float*)*gpu.MPI_SIZE);
	cudaMemcpy(d_arrA,h_arrA,sizeof(float*)*gpu.MPI_SIZE,cudaMemcpyDefault);

	gpu.tick("chain matrix array");
	for(int i = 0; i < 100; i++)
	{
		gpu.dot(A1,B1,arrOut[gpu.MYRANK]);
		matrix_idx = gpu.MYRANK;
		for(int i = 0; i < gpu.MPI_SIZE-1; i++)
		{
			MPI_Isend(arrOut[matrix_idx]->data, arrOut[matrix_idx]->size, MPI_FLOAT, destination, 100, MPI_COMM_WORLD, &request_send);
			matrix_idx = (matrix_idx - 1) < 0 ? gpu.MPI_SIZE-1 : (matrix_idx - 1);
			MPI_Irecv(arrOut[matrix_idx]->data, arrOut[matrix_idx]->size, MPI_FLOAT, source, 100, MPI_COMM_WORLD,&requests[i]);
		}


		MPI_Waitall(gpu.MPI_SIZE-1,requests,MPI_STATUSES_IGNORE);
		//hStackN(d_arrA,arrOut[0]->size, out,gpu.MPI_SIZE);

	}
	gpu.tock("chain matrix array");


	gpu.shutdown();



*/
}


void async_test()
{

	ClusterNet gpu = ClusterNet(1324);

	cudaSetDevice(0);
	Matrix *A1 = gpu.rand(10,2);
	Matrix *B1 = gpu.rand(2,10);
	cudaSetDevice(1);
	Matrix *A2 = ones(10,10);
	Matrix *B2 = empty(10,10);

	cudaSetDevice(0);
	cudaStream_t s;
	cudaStreamCreate(&s);
	//cudaDeviceEnablePeerAccess(1,0);
	Matrix *C1 = gpu.dot(A1,B1);

	cudaMemcpyPeerAsync(B2->data,1,C1->data,0,C1->bytes,s);

	cudaStreamSynchronize(s);
	printmat(C1);
	cudaSetDevice(1);
	printmat(B2);
	/*
	printmat(C1);
	add(C1,A2,A2);
	printmat(A2);
	*/


}



int main(int argc, char *argv[])
{

	//run_normal_net();
	//run_maxout_network();


	//async_test();


	/*
	ClusterNet gpus = ClusterNet(1234565);

	Matrix *X = read_hdf5("/home/tim/mnist_full_X.hdf5");
	Matrix *y = read_hdf5("/home/tim/mnist_full_y.hdf5");

	std::vector<int> layers;
	layers.push_back(512);

	BatchAllocator allocator = BatchAllocator();
	allocator.init(X,y,0.2,128,512,gpus, Single_GPU);
	DeepNeuralNetwork net = DeepNeuralNetwork(layers,Classification, gpus, allocator, 10);

	net.train();

	*/






	//cudaSetDevice(1);
	ClusterNet gpus = ClusterNet(1245);
	WikiMaxoutNet net = WikiMaxoutNet(gpus);
	net.run();








}





