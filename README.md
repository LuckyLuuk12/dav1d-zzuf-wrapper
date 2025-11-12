# Fuzzing Dav1d with ZZUF
## Azure (student) setup
First, if not done already, you go to [The Azure Home Page](https://azure.microsoft.com/en-us/).
Here you log in with your school / university student account.
From there you want to go and manage your resource groups [here](https://portal.azure.com/#view/HubsExtension/ServiceMenuBlade/~/resourcegroups/extension/Microsoft_Azure_Resources/menuId/ResourceManager/itemId/browseAll).
You should make a new resource group, give it some name (doesn't really matter what) and pick / check the region(s) you have **this is important to make a VM in the right region**.
Then you want to [make a VM](https://portal.azure.com/#view/Microsoft_Azure_ComputeHub/ComputeHubMenuBlade/~/virtualMachinesBrowse)
Most input fields in the form you will see are pretty straight forward but make sure you pick a region that works for your (selected) resource group.
Also check the size value (I recommend to pick the free/eligible one from the B series v2 because it is cheap and has 2 vcpu's vs only 1 from the normal B series)
Either pick a username and password or use your SSH key if you have one and review+create.

## VM Setup
First we make a `fuzzing` folder to run our fuzzer in
```sh
mkdir fuzzing
```
Second, outside this dir (in the home) we clone the dav1d repository and build on the Ubuntu (24.04 x64) VM:
```sh
git clone https://code.videolan.org/videolan/dav1d
```
Then we want to make sure all build tools are installed and run them:
```sh
sudo apt update 
sudo apt install meson
sudo apt install nasm
```
We go the the dav1d source folder and build 
```sh
cd ./dav1d
mkdir build
cd ./build
meson setup .. --default-library=static
ninja
```

After this completes we copy the dav1d binary to our `fuzzing` folder such that we can easily run it:
```sh
cd ../../
cp ./dav1d/build/tools/dav1d ./fuzzing/
```
Dav1d can now be run with this command when we're in the `fuzzing` folder
```sh
cd fuzzing # if not already in fuzzing folder
./dav1d -i path/to/someinputfile.ivf -o file.null
```

Now to run zuff we want to add our custom script / wrapper and add some samples.
```sh
cd fuzzing # if not already in fuzzing folder
mkdir samples
# put some samples in here, e.g. from https://send.zegs.me/small_av1s.zip unzipped
touch run_zzuf
nano run_zzuf
# paste the script in there -> ctrl+x -> y -> enter
chmod +x run_zzuf
./run_zzuf
```

you can safely exit the tmux screen with `ctrl+B` followed by `D`
and reattach any time with:
```sh
./run_zzuf attach <session>
```

The script supports some arguments to manage sessions as well:
```sh
./run_zuff 						        # starts a new session
./run_zuff attach <session>		# attach / view the table of a session
./run_zuff list 				      # prints a list of sessions and info about them
./run_zuff stop <session>		  # stops a running session (cannot be continued afterwards)
./run_zuff pause <session>		# pauses a running session (this allows to continue it)
./run_zuff continue <session>	# continues a paused session
```
