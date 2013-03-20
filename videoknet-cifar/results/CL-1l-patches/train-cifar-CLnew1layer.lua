----------------------------------------------------------------------
-- Run k-means on CIFAR10 dataset - 1st layer generation/load and test
----------------------------------------------------------------------

require 'image'
require 'nnx'
--require 'unsup'
require 'eex'
require 'trainLayer' -- functions for Clustering Learning on video
require 'slac'
require 'online-kmeans'

cmd = torch.CmdLine()
cmd:text('Options')
cmd:option('-display', false, 'display kernels')
cmd:option('-seed', 1, 'initial random seed')
cmd:option('-threads', 8, 'threads')
cmd:option('-inputsize', 5, 'size of each input patches')
cmd:option('-nkernels', 16, 'number of kernels to learn')
cmd:option('-niter', 15, 'nb of k-means iterations')
cmd:option('-batchsize', 1000, 'batch size for k-means\' inner loop')
cmd:option('-nsamples', 10000, 'nb of random training samples')
cmd:option('-initstd', 0.1, 'standard deviation to generate random initial templates')
cmd:option('-statinterval', 5000, 'interval for reporting stats/displaying stuff')
cmd:option('-savedataset', false, 'save modified dataset')
cmd:option('-classify', true, 'run classification train/test')
-- loss:
cmd:option('-loss', 'nll', 'type of loss function to minimize: nll | mse | margin')
-- training:
cmd:option('-save', 'results', 'subdirectory to save/log experiments in')
cmd:option('-plot', true, 'live plot')
cmd:option('-optimization', 'SGD', 'optimization method: SGD | ASGD | CG | LBFGS')
cmd:option('-learningRate', 1e-3, 'learning rate at t=0')
cmd:option('-batchSize', 1, 'mini-batch size (1 = pure stochastic)')
cmd:option('-weightDecay', 0, 'weight decay (SGD only)')
cmd:option('-momentum', 0, 'momentum (SGD only)')
cmd:option('-t0', 1, 'start averaging at t0 (ASGD only), in nb of epochs')
cmd:option('-maxIter', 2, 'maximum nb of iterations for CG and LBFGS')
cmd:text()
opt = cmd:parse(arg or {}) -- pass parameters to training files:

if not qt then
   opt.display = false
end

torch.manualSeed(opt.seed)
torch.setnumthreads(opt.threads)
torch.setdefaulttensortype('torch.DoubleTensor')

is = opt.inputsize
nk = opt.nkernels

opt.niter = 15
opt.slacmodel = true

----------------------------------------------------------------------
-- loading and processing dataset:
dofile '1_data_cifar.lua'

-- input image dateaset params:
ivch = trainData.data[1]:size(1) -- channels
ivhe = trainData.data[1]:size(2) -- height
ivwi = trainData.data[1]:size(3) -- width

trainData.data = trainData.data:double()
testData.data = testData.data:double()

nfpr = trainData:size() -- batch process size [video frames]

----------------------------------------------------------------------
----------------------------------------------------------------------
----------------------------------------------------------------------
print '==> generating CL unsupervised network:'

-- compute network CL train time
   time = sys.clock()

----------------------------------------------------------------------
print '==> generating filters for layer 1:'
nlayer = 1
nnf1 = 1 -- number of frames from input video to use
nk1 = 32
nk = nk1
poolsize = 2
cvstepsize = 1
normkernel = image.gaussian1D(7)
ovhe = (ivhe-is+1)/poolsize/cvstepsize -- output video feature height
ovwi = (ivwi-is+1)/poolsize/cvstepsize -- output video feature width


if opt.slacmodel then
   -- SLAC MODEL: nk1*N filters to learn, then narrow down to nk1:
   nk11 = nk1*2
   kernels1u, counts1 = trainLayer(nlayer, trainData.data, 1, nil, nk11, nnf1, is, false)
   -- kernels1, connTable1 = slac(kernels1, startN, finalN,tau,Delta) -- SLAC algorithm to aggregate kernels
   kernels1s, cTable1 = slac(kernels1u, nk11, nk1, 4, 4.5) -- SLAC algorithm to aggregate kernels
   --image.display{image=kernels1s:reshape(kernels1s:size(1),is,is), padding=2, symmetric=true, zoom=2} --slac kernels/groups
   nk1s=kernels1s:size(1)
   if opt.display then image.display{image=kernels1s:reshape(kernels1s:size(1),ivch,is,is), padding=2, symmetric=true, zoom=4, legend = 'Layer 1 filters'} end

else 
   -- AND/OR model or FULL CONNECT MODEL:
   -- get twice the kernels, then pick best ones:
   kernels1u, counts1 = trainLayer(nlayer, trainData.data, 1, nil, 2*nk1, nnf1, is)
   -- sort the kernels by importance and use only top kernels:
   _, j = torch.sort(counts,true)
   kernels1 = torch.Tensor(nk1,ivch, is,is)
   for i=1,nk1 do
      kernels1[i] = kernels1u[j[i]]
   end
   if opt.display then
      image.display{image=kernels1:reshape(kernels1:size(1),ivch,is,is), padding=2, symmetric=true, zoom=4, legend = 'Layer 1 filters'} end
end


   
----------------------------------------------------------------------
-- 1st layer
  
   -- Trainable Network
   vnet = nn.Sequential()
   if opt.slacmodel then 
      vnet:add(nn.SpatialConvolution(ivch, nk1s, is, is, cvstepsize,cvstepsize))
      vnet:add(nn.SpatialMaxMap(cTable1))
   else
      vnet:add(nn.SpatialConvolution(ivch, nk1, is, is, cvstepsize,cvstepsize))
   end
   --vnet:add(nn.Tanh())
   vnet:add(nn.HardShrink(0.1))
   --vnet:add(nn.HardTanh())
   vnet:add(nn.SpatialMaxPooling(poolsize,poolsize,poolsize,poolsize))
   --vnet:add(nn.SpatialContrastiveNormalization(nk1, normkernel,1e-3))


-- setup net/ load kernels into network:
vnet.modules[1].bias = vnet.modules[1].bias*0 -- set bias to 0!!! not needed
if opt.slacmodel then 
   kernels1_ = kernels1s:clone():div(nnf1*nk1*3) -- divide kernels so output of SpatialConv is about ~1 or more
   vnet.modules[1].weight = kernels1_:reshape(nk1s, ivch, is,is)
else 
   kernels1_ = kernels1:clone():div(nnf1*nk1*3) -- divide kernels so output of SpatialConv is about ~1 or more
   vnet.modules[1].weight = kernels1_:reshape(nk1, ivch, is,is)
end



----------------------------------------------------------------------
print '==> process dataset throught 1st layer:'
trainData2 = processLayer(nlayer, vnet, trainData.data, nk1, ovhe, ovwi)
testData2 = processLayer(nlayer, vnet, testData.data, nk1, ovhe, ovwi)

--report some statistics:
print('1st layer conv output std: '..vnet.modules[1].output:std()..' and mean: '..vnet.modules[1].output:mean())
print('1st layer output std: '..vnet.output:std()..' and mean: '..vnet.output:mean())


-- show a few outputs:
if opt.visualize then
   f256S_y = trainData2[{ {1,256},1 }]
   image.display{image=f256S_y, nrow=16, nrow=16, padding=2, zoom=2, 
            legend='Output 1st layer: first 256 examples, 1st feature'}
end
--
--
------------------------------------------------------------------------
----print '==> generating filters for layer 1:'
--nlayer = 2
--nnf2 = 1 -- just one frames goes into layer 2
--nk2 = 64
--nk = nk2
--is = 5
--fanin = 2 -- createCoCnxTable creates also 2*fanin connections 
--poolsize = 2
--cvstepsize = 1
--ovhe2 = (ovhe-is+1)/poolsize/cvstepsize -- output video feature height
--ovwi2 = (ovwi-is+1)/poolsize/cvstepsize -- output video feature width
--
--
---- OUTPUT Co-occurence CONNEX MODEL:
--print '==> Computing connection tables based on co-occurence of features'
--cTable1, kernels2 = createCoCnx(nlayer, trainData2[{{1,100}}], nk1, nk2, fanin, 'AND', opt.nsamples, nnf2, is, kernels1, false)
--
--image.display{image=kernels2:reshape(kernels2:size(1),is,is), padding=2, symmetric=true, nrow = 32, zoom=4, legend = 'Layer 2 filters'}
--
--
------------------------------------------------------------------------
---- 2nd layer
--
--   vnet2 = nn.Sequential()
--   vnet2:add(nn.SpatialConvolutionMap(cTable1, is, is, cvstepsize,cvstepsize)) -- connex table based on similarity of features
--   vnet2:add(nn.Tanh())
--   vnet2:add(nn.SpatialMaxPooling(2,2,2,2))
--   --vnet2:add(nn.SpatialContrastiveNormalization(nk2, normkernel,1e-3))
--   
--
---- setup net/ load kernels into network:
--vnet2.modules[1].bias = vnet2.modules[1].bias*0 -- set bias to 0!!! not needed
--kernels2_= kernels2:clone():div(nk2/2) -- divide kernels so output of SpatialConv is about ~1 or more
----vnet2.modules[1].weight = kernels2:reshape(nk2,nk1,is,is) --full connex filters
--vnet2.modules[1].weight = kernels2_:reshape(kernels2_:size(1),is,is)  -- OR-AND model *3/2 because of fanin and 2*fanin connnex table
--
------------------------------------------------------------------------
--print '==> process dataset throught 2nd layer:'
--
--trainData3 = processLayer(nlayer, vnet2, trainData2, nk2, ovhe2, ovwi2)
--testData3 = processLayer(nlayer, vnet2, testData2, nk2, ovhe2, ovwi2)
--
----report some statistics:
--print('2nd layer conv output std: '..vnet2.modules[1].output:std()..' and mean: '..vnet2.modules[1].output:mean())
--print('2nd layer output std: '..vnet2.output:std()..' and min: '..vnet2.output:min()..' and mean: '..vnet2.output:mean())
--
--
---- show a few outputs:
--if opt.visualize then
--   f256S_y = trainData3[{ {1,256},1 }]
--   image.display{image=f256S_y, nrow=16, nrow=16, padding=2, zoom=2, 
--            legend='Output 2nd layer: first 256 examples, 1st feature'}
--end
--
--
-- compute network creation time time 
time = sys.clock() - time
print("<net> time to CL train network = " .. (time*1000) .. 'ms')



----------------------------------------------------------------------
print "==> creating final test dataset"

l1netoutsize = ovhe -- 2 layers:
nk = nk1

trainDataF = {
   data = torch.Tensor(trsize, nk*(l1netoutsize)^2),
   labels = trainData.labels:clone(),
   size = function() return trsize end
  
}

testDataF = {
   data = torch.Tensor(tesize, nk*(l1netoutsize)^2),
   labels = testData.labels:clone(),
   size = function() return tesize end
}

trainDataF.data = trainData2
for t = 1,trainDataF:size() do
   --trainData2.data[t] = l1net:forward(trainData.data[t]:double())
   --xlua.progress(t, trainData:size())
end

testDataF.data = testData2
for t = 1,testDataF:size() do
   --testData2.data[t] = l1net:forward(testData.data[t]:double())
   --xlua.progress(t, testData:size())
end


trainDataF.data = trainDataF.data:reshape(trsize, nk1, l1netoutsize, l1netoutsize)
testDataF.data = testDataF.data:reshape(tesize, nk1, l1netoutsize, l1netoutsize)

-- relocate pointers to new dataset:
--trainData1 = trainData -- save original dataset
--testData1 = testData
trainData = trainDataF -- relocate new dataset
testData = testDataF

-- show a few outputs:
if opt.visualize then
   f256S_y = trainDataF.data[{ {1,256},1 }]
   image.display{image=f256S_y, nrow=16, nrow=16, padding=2, zoom=4, 
            legend='Output 2-layer net: first 256 examples, 1st feature'}
end

print '==> verify statistics'
channels = {'r','g','b'}
for i,channel in ipairs(channels) do
   trainMean = trainData.data[{ {},i }]:mean()
   trainStd = trainData.data[{ {},i }]:std()

   testMean = testData.data[{ {},i }]:mean()
   testStd = testData.data[{ {},i }]:std()

   print('training data, '..channel..'-channel, mean: ' .. trainMean)
   print('training data, '..channel..'-channel, standard deviation: ' .. trainStd)

   print('test data, '..channel..'-channel, mean: ' .. testMean)
   print('test data, '..channel..'-channel, standard deviation: ' .. testStd)
end


----------------------------------------------------------------------


----------------------------------------------------------------------
-- classifier for train/test:
if opt.classify then
   ----------------------------------------------------------------------
   print "==> creating classifier"
   
   opt.model = '2mlp-classifier'
   dofile '2_model.lua' 
   
   print "==> test network output:"
   print(model:forward(trainData.data[1]:double()))
   
   dofile '3_loss.lua' 
   dofile '4_train.lua'
   dofile '5_test.lua'
   
   ----------------------------------------------------------------------
   print "==> training classifier"
   
   while true do
      train()
      test()
   end
   
end


