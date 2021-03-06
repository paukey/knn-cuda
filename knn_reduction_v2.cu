#include<stdio.h>
#include<stdlib.h>
#include<string.h>
#include<float.h> //DBL_MAX
#include <cuda_runtime_api.h>

#define restrict __restrict__
#define PADDINGCLASS -2
#define EXP 2
#define OUTPUT_FILE "ocuda"
#define INPUT_FILE "data"

void printStats(size_t bytes, cudaEvent_t before, cudaEvent_t after, const char *msg);
void check_error(cudaError_t err, const char *msg);
void readInput(FILE* file, double* coords, double* coordsnew, int* classes, int spacedim, int numels, int newels);
void writeOutput(double* coords, int* classes, int spacedim, int numels);
__device__ int findMode(double4* elements, int classes_num, int k);
__global__ void findClass(double* coords, double* coordsnew, int* input_classes, double4* d_output, int spacedim, int classes_num, int numels, int offset, int newPointIndex, int newels, double* d_coordsDistances);
__device__ double distance(double* coords, double* coords2, int spacedim);
__global__ void findMin(double4* input, double* coords, double* coordsnew, int* classes, int classes_num, int spacedim, int numels, int offset, double4* result, int k, int newPointIndex, int eleInBlock, int newels, double* coordsDistances);
__device__ void swapdouble(double* x, double* y);
__device__ void swapInt(int* x, int* y);
__global__ void calcDistances(double* coords, double* coordsnew, int spacedim, int numels, int newels, double* coordsDistances);

//Declaration of shared-memory. It's going to contains partial minimum of distances
extern __shared__ double4 mPartial[];

int main(int argc, char *argv[])
{  
  int newels;                      //number of points we want classify
  int k;                           //number of nearest points we use to classify
  int numels;                      //total element already classified
  int spacedim;
  char filePath[255];              //path + filname of input file
  int classes_num;                 //number of classes
  double* h_coords;                //coords of existing points with a class
  double* h_coordsnew;             //coords of points we want to classify
  int* h_classes;                  //array contains the class for each points
  
  //*** Device-variables-declaration ***
  double* d_coords;
  double* d_coordsnew;
  double* d_coordsDistances;
  double* d_newcoordsDistances;
  double4* d_result; 
  int* d_classes;
  double4* d_output;
  //*** end-device-declaration
  
  //***cudaEvent-declaration***
  cudaEvent_t before_allocation, before_input, before_upload, before_knn, before_download;
  cudaEvent_t after_allocation, after_input, after_upload, after_knn, after_download;
  //***end-cudaEvent-declaration***
  
  if (argc > 2) 
  {
    strcpy(filePath, argv[1]);
    k = atoi(argv[2]);
  }
  else 
  {
    printf("how-to-use: knn <inputfile> <k> \n");
    exit(1);
  } 
  
  //***cuda-init-event***
  check_error(cudaEventCreate(&before_allocation), "create before_allocation cudaEvent");
  check_error(cudaEventCreate(&before_input), "create before_input cudaEvent");
  check_error(cudaEventCreate(&before_upload), "create before_upload cudaEvent");
  check_error(cudaEventCreate(&before_knn), "create before_knn cudaEvent");
  check_error(cudaEventCreate(&before_download), "create before_download cudaEvent");
  
  check_error(cudaEventCreate(&after_allocation), "create after_allocation cudaEvent");
  check_error(cudaEventCreate(&after_input), "create after_input cudaEvent");
  check_error(cudaEventCreate(&after_upload), "create after_upload cudaEvent");
  check_error(cudaEventCreate(&after_knn), "create after_knn cudaEvent");
  check_error(cudaEventCreate(&after_download), "create after_download cudaEvent");
  //***end-cuda-init-event***

  FILE *fp;
  if((fp = fopen(filePath, "r")) == NULL)
  {
        printf("No such file\n");
        exit(1);
  }
  
  fseek(fp, 0L, SEEK_END);
  float fileSize = ftell(fp);
  rewind(fp);
  
  int count = fscanf(fp, "%d,%d,%d,%d\n", &numels, &newels, &classes_num, &spacedim);
  int totalElements = numels + newels;

  //*** allocation ***
  cudaEventRecord(before_allocation);
  h_coords = (double*) malloc(sizeof(double)*totalElements*spacedim);
  h_coordsnew = (double*) malloc(sizeof(double)*newels*spacedim);    
  h_classes = (int*) malloc(sizeof(int)*totalElements);
  
  const int blockSize = 512;
  int numBlocks = (totalElements + blockSize - 1)/blockSize;
  
  //*** device-allocation ***
  check_error(cudaMalloc(&d_coords, totalElements*spacedim*sizeof(double)), "alloc d_coords_x");
  check_error(cudaMalloc(&d_output, ((totalElements + blockSize - 1)/blockSize)*4*sizeof(double)), "alloc d_output");
  check_error(cudaMalloc(&d_classes, totalElements*sizeof(int)), "alloc d_classes");
  check_error(cudaMalloc(&d_result, 4*k*sizeof(double)), "alloc d_result");
  check_error(cudaMalloc(&d_coordsDistances, (newels*totalElements)*sizeof(double)), "alloc d_coordsDistances");
  check_error(cudaMalloc(&d_newcoordsDistances, (newels*newels)*sizeof(double)), "alloc d_newcoordsDistances");
  check_error(cudaMalloc(&d_coordsnew, newels*spacedim*sizeof(double)), "alloc d_coordsnew");
  //*** end-device-allocation ***
  cudaEventRecord(after_allocation);
  
  ///***input-from-file***
  cudaEventRecord(before_input);
  readInput(fp, h_coords, h_coordsnew, h_classes, spacedim, numels, newels);
  cudaEventRecord(after_input);
  fclose(fp);
  ///***end-input-from-file***

  //***copy-arrays-on-device***
  cudaEventRecord(before_upload);
  check_error(cudaMemcpy(d_coords, h_coords, totalElements*spacedim*sizeof(double), cudaMemcpyHostToDevice), "copy d_coords");
  check_error(cudaMemcpy(d_classes, h_classes, totalElements*sizeof(int), cudaMemcpyHostToDevice), "copy d_classes");
  check_error(cudaMemcpy(d_coordsnew, h_coordsnew, newels*spacedim*sizeof(double), cudaMemcpyHostToDevice), "copy d_coordsnew");
  cudaEventRecord(after_upload);
  //***end-copy-arrays-on-device***
  
    cudaEventRecord(before_knn);
  calcDistances<<<numBlocks, blockSize>>>(d_coords, d_coordsnew, spacedim, numels, newels, d_coordsDistances);
  

  int i, j;
  for (i = 0; i < newels; i++)
  {
    numBlocks = (numels + blockSize - 1)/blockSize;
    j = 0;
    for (j = 0; j < k; j++)
    {
      findClass<<<numBlocks, blockSize, blockSize*4*sizeof(double)>>>(
      d_coords, d_coordsnew, d_classes,
      d_output,
      spacedim, classes_num,
      numels, j, i, newels, d_coordsDistances);
      
      findMin<<<1, blockSize, blockSize*4*sizeof(double)>>>(d_output, d_coords, d_coordsnew, d_classes, classes_num, spacedim, numels, j, d_result, k, i, numBlocks, newels, d_coordsDistances);
    }
    numels++;
  }
  cudaEventRecord(after_knn);
  
  cudaEventRecord(before_download);
  check_error(cudaMemcpy(h_coords, d_coords, spacedim*totalElements*sizeof(double), cudaMemcpyDeviceToHost), "download coords");
  check_error(cudaMemcpy(h_classes, d_classes, totalElements*sizeof(int), cudaMemcpyDeviceToHost), "download classes");
  cudaEventRecord(after_download);
  
  check_error(cudaEventSynchronize(after_download), "sync cudaEvents");
  printStats((totalElements+newels)*(1+spacedim)*sizeof(double) + totalElements*sizeof(int), before_allocation, after_allocation, "[time] allocation");
  printStats(fileSize, before_input, after_input, "[time] read input file");
  printStats(fileSize, before_upload, after_upload, "[time] upload host->device");
  printStats((spacedim*totalElements*sizeof(double) + totalElements*sizeof(int))*newels, before_knn, after_knn, "[time] knn algorithm");
  printStats((spacedim*totalElements*sizeof(double) + totalElements*sizeof(int))*newels, before_download, after_download, "[time] download device->host");
  
  writeOutput(h_coords, h_classes, spacedim, numels);
  return 0;
}

void check_error(cudaError_t err, const char *msg)
{
  if (err != cudaSuccess) 
  {
    fprintf(stderr, "%s : error %d (%s)\n", msg, err, cudaGetErrorString(err));
    exit(err);
  }
}

float runtime;
void printStats(size_t bytes, cudaEvent_t before, cudaEvent_t after, const char *msg)
{ 
  check_error(cudaEventElapsedTime(&runtime, before, after), msg);
  printf("%s %gms, %g GB/s\n", msg, runtime, bytes/runtime/(1024*1024));
}

//Parallel reduction to find the k-minimum distances
__global__ void findClass(
  double* coords, double* coordsnew,
  int* input_classes, double4* d_output,
  int spacedim, int classes_num, int numels, int offset, int newPointIndex, int newels, double* d_coordsDistances)
{
  int gid = offset + threadIdx.x + blockIdx.x*blockDim.x;
  int lid = threadIdx.x;
  mPartial[lid] = make_double4(-1, PADDINGCLASS, -1, -1);
  if (gid >= numels) return;  
  
  double min = d_coordsDistances[gid*newels + newPointIndex];
  double d;
  int c = input_classes[gid];
  int minID = gid;

  while (gid < numels)
  {
    d = d_coordsDistances[gid*newels + newPointIndex];
    if(d < min)
    {
      min = d;
      minID = gid;
      c = input_classes[gid];
    }
    gid += gridDim.x*blockDim.x;
  }

  mPartial[lid] = make_double4(min, (double)c, minID, -1);
  
  //Part 2: reduction in shared memory
  int stride = (blockDim.x)/2;
  while (stride > 0)
  {
    __syncthreads();
    if (lid < stride && mPartial[lid+stride].y != PADDINGCLASS && mPartial[lid].y != PADDINGCLASS && mPartial[lid+stride].x < mPartial[lid].x)
        mPartial[lid] = mPartial[lid+stride];
    stride /= 2;
  }

  /* Part 3: save the block's result in global memory */
  if (lid == 0)
    d_output[blockIdx.x] = mPartial[0];
}

__global__ void findMin(double4* input, double* coords, double* coordsnew, int* classes, int classes_num, int spacedim, int numels, int offset, double4* result, int k, int newPointIndex, int eleInBlock, int newels, double* coordsDistances)
{
  int gid = threadIdx.x + blockIdx.x*blockDim.x;
  int lid = threadIdx.x;
  mPartial[lid] = make_double4(-1, PADDINGCLASS, -1, -1);
  if (gid >= eleInBlock || gid >= blockDim.x) return;

  double distmin = input[gid].x;
  double classmin = input[gid].y;
  double gidMin = input[gid].z;
       
  while (gid < eleInBlock)
  {
    if(input[gid].x < distmin)
    {
      distmin = input[gid].x;
      classmin = input[gid].y;
      gidMin = input[gid].z;
    }
    gid += gridDim.x*blockDim.x;
  }
    
  mPartial[lid] = make_double4(distmin, classmin, gidMin, -1);

  //Part 2: reduction in shared memory
  int stride = (blockDim.x)/2;
  while (stride > 0)
  {
    __syncthreads();
    if (lid < stride && mPartial[lid+stride].y != PADDINGCLASS && mPartial[lid].y != PADDINGCLASS && mPartial[lid+stride].x < mPartial[lid].x)
      mPartial[lid] = mPartial[lid + stride];
    stride /= 2;
  }

  /* Part 3: save the block's result in global memory */
  if (lid == 0)
  {    
    input[0] = mPartial[0];
    int minID = mPartial[0].z;
    
    int i = 0;
    for (i = 0; i < spacedim; i++)
      swapdouble(&(coords[spacedim*minID+i]), &(coords[offset*spacedim+i]));
    
    for (i = 0; i < newels; i++)
      swapdouble(&(coordsDistances[newels*minID + i]), &(coordsDistances[newels*offset+i]));
      
    swapInt(&(classes[minID]), &(classes[offset]));    
    result[offset] = input[0];
    if (offset == k-1)
    {
      int j;
      for (j = 0; j < spacedim; j++)
          coords[spacedim*numels+j] = coordsnew[spacedim*newPointIndex + j];
                
      classes[numels] = findMode(result, classes_num, k);
    }
  }
}

__global__ void calcDistances(double* coords, double* coordsnew, int spacedim, int numels, int newels, double* coordsDistances)
{
  int point = threadIdx.x + blockIdx.x*blockDim.x;
  int totalElements = numels + newels;
  if (point >= totalElements) return;
  
  int i = 0;
  if (point < numels)
  {
    //per ogni punto - mi calcolo le distanze con i punti newles
    for (i = 0; i < newels; i++)
      coordsDistances[point*newels+i] = distance((point*spacedim+coords), (i*spacedim+coordsnew), spacedim);  
  }
  else 
  {
    //punto da determinare, mi calcolo la distanza con il resto dei punti newels
    int index = point - numels;
    for (i = 0; i < newels; i++)
    {
        //distance per me stesso
        if (i == index)
          coordsDistances[point*newels+i] = DBL_MAX;
        else
          coordsDistances[point*newels+i] = distance((index*spacedim+coordsnew), (i*spacedim+coordsnew), spacedim);
    }
  }  
}

// read input from file
void readInput(FILE* file, double* coords, double* coordsnew, int* classes, int spacedim, int numels, int newels)
{
  int i, j;
  int count;
  for(i=0; i<numels; i++)
  {
    for (j = 0; j < spacedim; j++)
      count = fscanf(file, "%lf,", &(coords[i*spacedim +j]));
    count = fscanf(file, "%d\n", &(classes[i]));
  }
   
  for(i = 0; i < newels; i++)
  {
    for (j = 0; j < spacedim; j++)
      count = fscanf(file, "%lf,", &(coordsnew[i*spacedim+j]));
    count = fscanf(file, "-1\n");
  }
  count++;
}

//Write Output on file
void writeOutput(double* coords, int* classes, int spacedim, int numels)
{
  FILE *fp;
  fp = fopen(OUTPUT_FILE, "w");
  int i, j;
  for( i = 0; i < numels; i++)
  {
    for (j = 0; j < spacedim; j++)
      fprintf(fp, "%lf,", coords[i*spacedim+j]);
    
    fprintf(fp, "%d\n", classes[i]);
  }
  fclose(fp); 
}

//multidimensional euclidian distance
__device__ double distance(double* coords, double* coords2, int spacedim)
{
  double sum = 0;
  int i;
  for (i = 0; i < spacedim; i++)
  {
    double diff = coords[i] - coords2[i];
    sum += diff*diff;
  }  
  return sum;
}

__device__ void swapdouble(double* x, double* y)
{
  double tmp = *x;
  *x = *y;
  *y = tmp;
}

__device__ void swapInt(int* x, int* y)
{
  int tmp = *x;
  *x = *y;
  *y = tmp;
}

__device__ int findMode(double4* elements, int classes_num, int k)
{
  int* classCount = (int*) (malloc(sizeof(int)*classes_num));
  int i;
  for (i = 0; i < classes_num; i++)
    classCount[i] = 0;
       
  for (i = 0; i < k; i++)
    classCount[(int)(elements[i].y)]++;
    
  int max = 0;
  int maxValue = classCount[0];
  for (i = 1; i < classes_num; i++)
  {
    int value = classCount[i];
    if (value > maxValue)
    {
      max = i;
      maxValue = value;
    }
    else if (value != 0 && maxValue == value)
    {
        int j = 0;
        for (j = 0; j < k; j++)
        {
          if (elements[j].y == i)
          {
            max = i;
            break;
          }
          else if (elements[j].y == max)
            break;
        }
    }
  }
  
  free(classCount);
  return max;
}
