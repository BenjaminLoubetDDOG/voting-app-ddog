var app = angular.module('catsvsdogs', []);
var socket = io.connect();

var bg1 = document.getElementById('background-stats-1');
var bg2 = document.getElementById('background-stats-2');

app.controller('statsCtrl', function($scope, $http){
  $scope.aPercent = 50;
  $scope.bPercent = 50;
  $scope.loading = false;
  $scope.statusMessage = '';
  $scope.statusClass = '';

  var updateScores = function(){
    socket.on('scores', function (json) {
       data = JSON.parse(json);
       var a = parseInt(data.a || 0);
       var b = parseInt(data.b || 0);

       var percentages = getPercentages(a, b);

       bg1.style.width = percentages.a + "%";
       bg2.style.width = percentages.b + "%";

       $scope.$apply(function () {
         $scope.aPercent = percentages.a;
         $scope.bPercent = percentages.b;
         $scope.total = a + b;
       });
    });
  };

  // User Action: Refresh Data (generates RUM/APM correlation)
  $scope.refreshData = function() {
    $scope.loading = true;
    $scope.statusMessage = 'Refreshing data...';
    $scope.statusClass = 'info';
    
    $http.post('/api/refresh')
      .then(function(response) {
        $scope.loading = false;
        $scope.statusMessage = 'Data refreshed successfully!';
        $scope.statusClass = 'success';
        console.log('Refresh successful:', response.data);
        
        // Clear message after 3 seconds
        setTimeout(function() {
          $scope.$apply(function() {
            $scope.statusMessage = '';
          });
        }, 3000);
      })
      .catch(function(error) {
        $scope.loading = false;
        $scope.statusMessage = 'Failed to refresh data';
        $scope.statusClass = 'error';
        console.error('Refresh failed:', error);
        
        setTimeout(function() {
          $scope.$apply(function() {
            $scope.statusMessage = '';
          });
        }, 3000);
      });
  };

  // User Action: Get Stats (generates RUM/APM correlation)
  $scope.getStats = function() {
    $scope.statusMessage = 'Loading detailed stats...';
    $scope.statusClass = 'info';
    
    $http.get('/api/stats')
      .then(function(response) {
        var stats = response.data;
        $scope.statusMessage = `Total: ${stats.total} votes | Cats: ${stats.percentages.a}% | Dogs: ${stats.percentages.b}%`;
        $scope.statusClass = 'success';
        console.log('Stats retrieved:', stats);
        
        setTimeout(function() {
          $scope.$apply(function() {
            $scope.statusMessage = '';
          });
        }, 5000);
      })
      .catch(function(error) {
        $scope.statusMessage = 'Failed to get stats';
        $scope.statusClass = 'error';
        console.error('Stats failed:', error);
        
        setTimeout(function() {
          $scope.$apply(function() {
            $scope.statusMessage = '';
          });
        }, 3000);
      });
  };

  // User Action: Export Results (generates RUM/APM correlation)
  $scope.exportResults = function() {
    $scope.statusMessage = 'Preparing export...';
    $scope.statusClass = 'info';
    
    $http.get('/api/export')
      .then(function(response) {
        // Trigger download
        var blob = new Blob([JSON.stringify(response.data, null, 2)], { type: 'application/json' });
        var url = window.URL.createObjectURL(blob);
        var a = document.createElement('a');
        a.href = url;
        a.download = 'voting-results.json';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        window.URL.revokeObjectURL(url);
        
        $scope.statusMessage = 'Results exported successfully!';
        $scope.statusClass = 'success';
        console.log('Export successful:', response.data);
        
        setTimeout(function() {
          $scope.$apply(function() {
            $scope.statusMessage = '';
          });
        }, 3000);
      })
      .catch(function(error) {
        $scope.statusMessage = 'Failed to export results';
        $scope.statusClass = 'error';
        console.error('Export failed:', error);
        
        setTimeout(function() {
          $scope.$apply(function() {
            $scope.statusMessage = '';
          });
        }, 3000);
      });
  };

  var init = function(){
    document.body.style.opacity=1;
    updateScores();
  };
  socket.on('message',function(data){
    init();
  });
});

function getPercentages(a, b) {
  var result = {};

  if (a + b > 0) {
    result.a = Math.round(a / (a + b) * 100);
    result.b = 100 - result.a;
  } else {
    result.a = result.b = 50;
  }

  return result;
}