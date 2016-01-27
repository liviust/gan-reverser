require 'torch'
require 'image'
require 'paths'
require 'pl' -- this is somehow responsible for lapp working in qlua mode
require 'optim'
require 'unsup'
ok, DISP = pcall(require, 'display')
if not ok then print('display not found. unable to plot') end
DATASET = require 'dataset'
NN_UTILS = require 'utils.nn_utils'
MODELS = require 'models'

OPT = lapp[[
    --batchSize     (default 32)
    --seed          (default 1)
    --gpu           (default 0)
    --threads       (default 8)            Number of threads
    --G             (default "logs/adversarial.net")
    --R             (default "logs/r_3x32x32_nd100_normal.net")
    --dataset       (default "NONE")       Directory that contains *.jpg images
    --writeTo       (default "r_results")  Directory in which to save images
]]

NORMALIZE = false
START_TIME = os.time()

if OPT.gpu < 0 or OPT.gpu > 3 then OPT.gpu = false end
print(OPT)

-- fix seed
math.randomseed(OPT.seed)
torch.manualSeed(OPT.seed)

-- threads
torch.setnumthreads(OPT.threads)
print('<torch> set nb of threads to ' .. torch.getnumthreads())

-- possible output of disciminator
CLASSES = {"0", "1"}
Y_GENERATOR = 0
Y_NOT_GENERATOR = 1

-- run on gpu if chosen
-- We have to load all kinds of libraries here, otherwise we risk crashes when loading
-- saved networks afterwards
print("<trainer> starting gpu support...")
require 'nn'
require 'cutorch'
require 'cunn'
require 'dpnn'
if OPT.gpu then
    cutorch.setDevice(OPT.gpu + 1)
    cutorch.manualSeed(OPT.seed)
    print(string.format("<trainer> using gpu device %d", OPT.gpu))
end
torch.setdefaulttensortype('torch.FloatTensor')

function main()
    -- load previous network
    print(string.format("<trainer> loading trained G from file '%s'", OPT.G))
    local tmp = torch.load(OPT.G)
    MODEL_G = tmp.G
    MODEL_G:evaluate()
    OPT.noiseDim = tmp.opt.noiseDim
    OPT.noiseMethod = tmp.opt.noiseMethod
    OPT.height = tmp.opt.height
    OPT.width = tmp.opt.width
    OPT.colorSpace = tmp.opt.colorSpace

    ----------------------------------------------------------------------
    -- set stuff dependent on height, width and colorSpace
    ----------------------------------------------------------------------
    -- axis of images: 3 channels, <scale> height, <scale> width
    if OPT.colorSpace == "y" then
        IMG_DIMENSIONS = {1, OPT.height, OPT.width}
    else
        IMG_DIMENSIONS = {3, OPT.height, OPT.width}
    end

    -- get/create dataset
    assert(OPT.dataset ~= "NONE")
    DATASET.setColorSpace(OPT.colorSpace)
    DATASET.setFileExtension("jpg")
    DATASET.setHeight(IMG_DIMENSIONS[2])
    DATASET.setWidth(IMG_DIMENSIONS[3])
    DATASET.setDirs({OPT.dataset})
    ----------------------------------------------------------------------

    -- Initialize G in autoencoder form
    -- G is a Sequential that contains (1) G Encoder and (2) G Decoder (both again Sequentials)
    print(string.format("<trainer> loading trained R from file '%s'", OPT.R))
    local tmp = torch.load(OPT.R)
    MODEL_R = tmp.R
    MODEL_R:evaluate()

    if OPT.gpu == false then
        MODEL_G:float()
        MODEL_R:float()
    end

    print("Varying components...")
    local nbSteps = 16
    local steps
    if OPT.noiseMethod == "uniform" then
        steps = torch.linspace(-1, 1, nbSteps)
    else
        steps = torch.linspace(-3, 3, nbSteps)
    end
    local noise = NN_UTILS.createNoiseInputs(1)
    --local face = MODEL_G:forward(NN_UTILS.createNoiseInputs(1)):clone()
    --face = face[1]

    noise = torch.repeatTensor(noise[1], OPT.noiseDim*nbSteps, 1)
    --local variations = torch.Tensor(OPT.noiseDim*10, IMG_DIMENSIONS[1], IMG_DIMENSIONS[2], IMG_DIMENSIONS[3])
    local imgIdx = 1
    for i=1,OPT.noiseDim do
        for j=1,nbSteps do
            noise[imgIdx][i] = steps[j]
            imgIdx = imgIdx + 1
        end
    end
    local variations = NN_UTILS.forwardBatched(MODEL_G, noise, OPT.batchSize):clone()
    variations = image.toDisplayTensor{input=variations, nrow=nbSteps, min=0, max=1.0}
    image.save(paths.concat(OPT.writeTo, 'variations.jpg'), variations)

    print("Loading images...")
    --local images = DATASET.loadImages(1, 50000)
    local noise = NN_UTILS.createNoiseInputs(10000)
    local images = NN_UTILS.forwardBatched(MODEL_G, noise, OPT.batchSize)

    print("Converting images to attributes...")
    local attributes = NN_UTILS.forwardBatched(MODEL_R, images, OPT.batchSize)
    --local attributes = binarize(NN_UTILS.forwardBatched(MODEL_R, images, OPT.batchSize))
    print(attributes[1])

    print("Clustering...")
    local nbClusters = 20
    local nbIterations = 15
    local centroids, counts = unsup.kmeans(attributes, nbClusters, nbIterations)
    local img2cluster = {}
    local cluster2imgs = {}
    for i=1,nbClusters do
        table.insert(cluster2imgs, {})
    end

    for i=1,attributes:size(1) do
        local minDist = nil
        local minDistCluster = nil
        for j=1,nbClusters do
            --local dist = torch.dist(attributes[i], centroids[j])
            local dist = cosineDistance(attributes[i], centroids[j])
            if minDist == nil or dist < minDist then
                minDist = dist
                minDistCluster = j
            end
        end
        img2cluster[i] = minDistCluster
        table.insert(cluster2imgs[minDistCluster], images[i])
    end

    local averageFaces = {}
    for i=1,nbClusters do
        local clusterImgs = cluster2imgs[i]
        local face = torch.zeros(IMG_DIMENSIONS[1], IMG_DIMENSIONS[2], IMG_DIMENSIONS[3])
        for j=1,#clusterImgs do
            face:add(clusterImgs[j])
        end
        face:div(#clusterImgs)
        table.insert(averageFaces, face)
    end

    print("Save images of clusters...")
    for i=1,nbClusters do
        if #cluster2imgs[i] > 0 then
            local tnsr = torch.Tensor(1 + #cluster2imgs[i], IMG_DIMENSIONS[1], IMG_DIMENSIONS[2], IMG_DIMENSIONS[3])
            tnsr[1] = averageFaces[i]
            for j=1,#cluster2imgs[i] do
                tnsr[1+j] = cluster2imgs[i][j]
            end
            tnsr = NN_UTILS.toRgb(tnsr, OPT.colorSpace)
            tnsr = image.toDisplayTensor{input=tnsr, nrow=math.ceil(math.sqrt(tnsr:size(1))), min=0, max=1.0}
            image.save(paths.concat(OPT.writeTo, string.format('cluster_%02d.jpg', i)), tnsr)
        end
    end

    print("Sorting by similarity...")
    local nbSimilarNeedles = 5
    for i=1,nbSimilarNeedles do
        local atts = attributes[i*100]
        local similar = {}
        for j=1,attributes:size(1) do
            --table.insert(similar, {j, torch.dist(atts, attributes[j])})
            table.insert(similar, {j, cosineDistance(atts, attributes[j])})
        end
        table.sort(similar, function(a,b) return a[2]>b[2] end)
        --print(similar)

        local n = math.min(100, #similar)
        local tnsr = torch.Tensor(n, IMG_DIMENSIONS[1], IMG_DIMENSIONS[2], IMG_DIMENSIONS[3])
        for j=1,n do
            tnsr[j] = images[similar[j][1]]
        end

        tnsr = NN_UTILS.toRgb(tnsr, OPT.colorSpace)
        tnsr = image.toDisplayTensor{input=tnsr, nrow=math.ceil(math.sqrt(tnsr:size(1))), min=0, max=1.0}
        image.save(paths.concat(OPT.writeTo, string.format('similar_%02d.jpg', i)), tnsr)
    end
end

function binarize(attributes)
    local tnsr = torch.Tensor():resizeAs(attributes)
    for row=1,attributes:size(1) do
        for col=1,attributes:size(2) do
            local val = attributes[row][col]
            if val < -0.15 then
                val = -1
            elseif val <= 0.15 then
                val = 0
            else
                val = 1
            end
            tnsr[row][col] = val
        end
    end
    return tnsr
end

function cosineDistance(v1, v2)
    local cos = nn.CosineDistance()
    local result = cos:forward({v1, v2})
    return result[1]
end

-------
main()